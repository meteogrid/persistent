{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
-- | A MySQL backend for @persistent@.
module Database.Persist.MySQL
    ( withMySQLPool
    , withMySQLConn
    , createMySQLPool
    , module Database.Persist
    , module Database.Persist.GenericSql
    , MySQL.ConnectInfo(..)
    , MySQLBase.SSLInfo(..)
    , MySQL.defaultConnectInfo
    , MySQLBase.defaultSSLInfo
    , MySQLConf(..)
    ) where

import Control.Arrow
import Control.Monad (mzero)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Error (ErrorT(..))
import Data.Aeson
import Data.ByteString (ByteString)
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.IORef
import Data.List (find, intercalate, sort, groupBy)
import Data.Text (Text, pack)
-- import Data.Time.LocalTime (localTimeToUTC, utc)
import System.Environment (getEnvironment)

import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Database.Persist hiding (Entity (..))
import Database.Persist.Store
import Database.Persist.GenericSql hiding (Key(..))
import Database.Persist.GenericSql.Internal
import Database.Persist.EntityDef

import qualified Database.MySQL.Simple        as MySQL
import qualified Database.MySQL.Simple.Param  as MySQL
import qualified Database.MySQL.Simple.Result as MySQL
import qualified Database.MySQL.Simple.Types  as MySQL

import qualified Database.MySQL.Base          as MySQLBase
import qualified Database.MySQL.Base.Types    as MySQLBase



-- | Create a MySQL connection pool and run the given action.
-- The pool is properly released after the action finishes using
-- it.  Note that you should not use the given 'ConnectionPool'
-- outside the action since it may be already been released.
withMySQLPool :: MonadIO m =>
                 MySQL.ConnectInfo
              -- ^ Connection information.
              -> Int
              -- ^ Number of connections to be kept open in the pool.
              -> (ConnectionPool -> m a)
              -- ^ Action to be executed that uses the connection pool.
              -> m a
withMySQLPool ci = withSqlPool $ open' ci


-- | Create a MySQL connection pool.  Note that it's your
-- responsability to properly close the connection pool when
-- unneeded.  Use 'withMySQLPool' for automatic resource control.
createMySQLPool :: MonadIO m =>
                   MySQL.ConnectInfo
                -- ^ Connection information.
                -> Int
                -- ^ Number of connections to be kept open in the pool.
                -> m ConnectionPool
createMySQLPool ci = createSqlPool $ open' ci


-- | Same as 'withMySQLPool', but instead of opening a pool
-- of connections, only one connection is opened.
withMySQLConn :: C.ResourceIO m =>
                 MySQL.ConnectInfo
              -- ^ Connection information.
              -> (Connection -> m a)
              -- ^ Action to be executed that uses the connection.
              -> m a
withMySQLConn = withSqlConn . open'


-- | Internal function that opens a connection to the MySQL
-- server.
open' :: MySQL.ConnectInfo -> IO Connection
open' ci = do
    conn <- MySQL.connect ci
    MySQLBase.autocommit conn False -- disable autocommit!
    smap <- newIORef $ Map.empty
    return Connection
        { prepare    = prepare' conn
        , stmtMap    = smap
        , insertSql  = insertSql'
        , close      = MySQL.close conn
        , migrateSql = migrate' ci
        , begin      = const $ MySQL.execute_ conn "start transaction" >> return ()
        , commitC    = const $ MySQL.commit   conn
        , rollbackC  = const $ MySQL.rollback conn
        , escapeName = pack . escapeDBName
        , noLimit    = "LIMIT 18446744073709551615"
        -- This noLimit is suggested by MySQL's own docs, see
        -- <http://dev.mysql.com/doc/refman/5.5/en/select.html>
        }

-- | Prepare a query.  We don't support prepared statements, but
-- we'll do some client-side preprocessing here.
prepare' :: MySQL.Connection -> Text -> IO Statement
prepare' conn sql = do
    let query = MySQL.Query (T.encodeUtf8 sql)
    return Statement
        { finalize = return ()
        , reset = return ()
        , execute = execute' conn query
        , withStmt = withStmt' conn query
        }


-- | SQL code to be executed when inserting an entity.
insertSql' :: DBName -> [DBName] -> Either Text (Text, Text)
insertSql' t cols = Right (doInsert, "SELECT LAST_INSERT_ID()")
    where
      doInsert = pack $ concat
        [ "INSERT INTO "
        , escapeDBName t
        , "("
        , intercalate "," $ map escapeDBName cols
        , ") VALUES("
        , intercalate "," (map (const "?") cols)
        , ")"
        ]


-- | Execute an statement that doesn't return any results.
execute' :: MySQL.Connection -> MySQL.Query -> [PersistValue] -> IO ()
execute' conn query vals = MySQL.execute conn query (map P vals) >> return ()


-- | Execute an statement that does return results.  The results
-- are fetched all at once and stored into memory.
withStmt' :: C.ResourceIO m
          => MySQL.Connection
          -> MySQL.Query
          -> [PersistValue]
          -> C.Source m [PersistValue]
withStmt' conn query vals = C.sourceIO (liftIO   openS )
                                       (liftIO . closeS)
                                       (liftIO . pullS )
  where
    openS = do
      -- Execute the query
      MySQLBase.query conn =<< MySQL.formatQuery conn query (map P vals)
      result <- MySQLBase.storeResult conn

      -- Find out the type of the columns
      fields <- MySQLBase.fetchFields result
      let getters = [ maybe PersistNull (getGetter (MySQLBase.fieldType f) f . Just) | f <- fields]

      -- Ready to go!
      return (result, getters)

    closeS (result, _) = MySQLBase.freeResult result

    pullS (result, getters) = do
      row <- MySQLBase.fetchRow result
      case row of
        [] -> MySQLBase.freeResult result >> return C.IOClosed
        _  -> return $ C.IOOpen $ zipWith ($) getters row


-- | @newtype@ around 'PersistValue' that supports the
-- 'MySQL.Param' type class.
newtype P = P PersistValue

instance MySQL.Param P where
    render (P (PersistText t))        = MySQL.render t
    render (P (PersistByteString bs)) = MySQL.render bs
    render (P (PersistInt64 i))       = MySQL.render i
    render (P (PersistDouble d))      = MySQL.render d
    render (P (PersistBool b))        = MySQL.render b
    render (P (PersistDay d))         = MySQL.render d
    render (P (PersistTimeOfDay t))   = MySQL.render t
    render (P (PersistUTCTime t))     = MySQL.render t
    render (P PersistNull)            = MySQL.render MySQL.Null
    render (P (PersistList _))        =
        error "Refusing to serialize a PersistList to a MySQL value"
    render (P (PersistMap _))         =
        error "Refusing to serialize a PersistMap to a MySQL value"
    render (P (PersistObjectId _))    =
        error "Refusing to serialize a PersistObjectId to a MySQL value"


-- | @Getter a@ is a function that converts an incoming value
-- into a data type @a@.
type Getter a = MySQLBase.Field -> Maybe ByteString -> a

-- | Helper to construct 'Getter'@s@ using 'MySQL.Result'.
convertPV :: MySQL.Result a => (a -> b) -> Getter b
convertPV f = (f .) . MySQL.convert

-- | Get the corresponding @'Getter' 'PersistValue'@ depending on
-- the type of the column.
getGetter :: MySQLBase.Type -> Getter PersistValue
-- Bool
getGetter MySQLBase.Tiny       = convertPV PersistBool
-- Int64
getGetter MySQLBase.Int24      = convertPV PersistInt64
getGetter MySQLBase.Short      = convertPV PersistInt64
getGetter MySQLBase.Long       = convertPV PersistInt64
getGetter MySQLBase.LongLong   = convertPV PersistInt64
-- Double
getGetter MySQLBase.Float      = convertPV PersistDouble
getGetter MySQLBase.Double     = convertPV PersistDouble
getGetter MySQLBase.Decimal    = convertPV PersistDouble
getGetter MySQLBase.NewDecimal = convertPV PersistDouble
-- Text
getGetter MySQLBase.VarChar    = convertPV PersistText
getGetter MySQLBase.VarString  = convertPV PersistText
getGetter MySQLBase.String     = convertPV PersistText
-- ByteString
getGetter MySQLBase.Blob       = convertPV PersistByteString
getGetter MySQLBase.TinyBlob   = convertPV PersistByteString
getGetter MySQLBase.MediumBlob = convertPV PersistByteString
getGetter MySQLBase.LongBlob   = convertPV PersistByteString
-- Time-related
getGetter MySQLBase.Time       = convertPV PersistTimeOfDay
getGetter MySQLBase.DateTime   = convertPV PersistUTCTime
getGetter MySQLBase.Timestamp  = convertPV PersistUTCTime
getGetter MySQLBase.Date       = convertPV PersistDay
getGetter MySQLBase.NewDate    = convertPV PersistDay
getGetter MySQLBase.Year       = convertPV PersistDay
-- Null
getGetter MySQLBase.Null       = \_ _ -> PersistNull
-- Controversial conversions
getGetter MySQLBase.Set        = convertPV PersistText
getGetter MySQLBase.Enum       = convertPV PersistText
-- Unsupported
getGetter other = error $ "MySQL.getGetter: type " ++
                  show other ++ " not supported."


----------------------------------------------------------------------


-- | Create the migration plan for the given 'PersistEntity'
-- @val@.
migrate' :: PersistEntity val
         => MySQL.ConnectInfo
         -> [EntityDef]
         -> (Text -> IO Statement)
         -> val
         -> IO (Either [Text] [(Bool, Text)])
migrate' connectInfo allDefs getter val = do
    let name = entityDB $ entityDef val
    old <- getColumns connectInfo getter $ entityDef val
    let new = second (map udToPair) $ mkColumns allDefs val
    case (old, partitionEithers old) of
      -- Nothing found, create everything
      ([], _) -> do
        let addTable = AddTable $ concat
                [ "CREATE TABLE "
                , escapeDBName name
                , "("
                , escapeDBName $ entityID $ entityDef val
                , " BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"
                , concatMap (\x -> ',' : showColumn x) $ fst new
                , ")"
                ]
        let uniques = flip concatMap (snd new) $ \(uname, ucols) ->
                      [ AlterTable name $
                        AddUniqueConstraint uname $
                        map (findTypeOfColumn allDefs name) ucols ]
        let foreigns = do
              Column cname _ _ _ (Just (refTblName, _)) <- fst new
              return $ AlterColumn name (cname, addReference allDefs refTblName)
        return $ Right $ map showAlterDb $ addTable : uniques ++ foreigns
      -- No errors and something found, migrate
      (_, ([], old')) -> do
        let (acs, ats) = getAlters allDefs name new $ partitionEithers old'
            acs' = map (AlterColumn name) acs
            ats' = map (AlterTable  name) ats
        return $ Right $ map showAlterDb $ acs' ++ ats'
      -- Errors
      (_, (errs, _)) -> return $ Left errs


-- | Find out the type of a column.
findTypeOfColumn :: [EntityDef] -> DBName -> DBName -> (DBName, FieldType)
findTypeOfColumn allDefs name col =
    maybe (error $ "Could not find type of column " ++
                   show col ++ " on table " ++ show name ++
                   " (allDefs = " ++ show allDefs ++ ")")
          ((,) col) $ do
            entDef   <- find ((== name) . entityDB) allDefs
            fieldDef <- find ((== col)  . fieldDB) (entityFields entDef)
            return (fieldType fieldDef)


-- | Helper for 'AddRefence' that finds out the 'entityID'.
addReference :: [EntityDef] -> DBName -> AlterColumn
addReference allDefs name = AddReference name id_
    where
      id_ = maybe (error $ "Could not find ID of entity " ++ show name
                         ++ " (allDefs = " ++ show allDefs ++ ")")
                  id $ do
                    entDef <- find ((== name) . entityDB) allDefs
                    return (entityID entDef)

data AlterColumn = Change Column
                 | Add Column
                 | Drop
                 | Default String
                 | NoDefault
                 | Update String
                 | AddReference DBName DBName
                 | DropReference DBName

type AlterColumn' = (DBName, AlterColumn)

data AlterTable = AddUniqueConstraint DBName [(DBName, FieldType)]
                | DropUniqueConstraint DBName

data AlterDB = AddTable String
             | AlterColumn DBName AlterColumn'
             | AlterTable DBName AlterTable


udToPair :: UniqueDef -> (DBName, [DBName])
udToPair ud = (uniqueDBName ud, map snd $ uniqueFields ud)


----------------------------------------------------------------------


-- | Returns all of the 'Column'@s@ in the given table currently
-- in the database.
getColumns :: MySQL.ConnectInfo
           -> (Text -> IO Statement)
           -> EntityDef
           -> IO [Either Text (Either Column (DBName, [DBName]))]
getColumns connectInfo getter def = do
    -- Find out all columns.
    stmtClmns <- getter "SELECT COLUMN_NAME, \
                               \IS_NULLABLE, \
                               \DATA_TYPE, \
                               \COLUMN_DEFAULT \
                        \FROM INFORMATION_SCHEMA.COLUMNS \
                        \WHERE TABLE_SCHEMA = ? \
                          \AND TABLE_NAME   = ? \
                          \AND COLUMN_NAME <> ?"
    inter <- C.runResourceT $ withStmt stmtClmns vals C.$$ CL.consume
    cs <- C.runResourceT $ CL.sourceList inter C.$$ helperClmns -- avoid nested queries

    -- Find out the constraints.
    stmtCntrs <- getter "SELECT CONSTRAINT_NAME, \
                               \COLUMN_NAME \
                        \FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
                        \WHERE TABLE_SCHEMA = ? \
                          \AND TABLE_NAME   = ? \
                          \AND COLUMN_NAME <> ? \
                          \AND REFERENCED_TABLE_SCHEMA IS NULL \
                        \ORDER BY CONSTRAINT_NAME, \
                                 \COLUMN_NAME"
    us <- C.runResourceT $ withStmt stmtCntrs vals C.$$ helperCntrs

    -- Return both
    return $ cs ++ us
  where
    vals = [ PersistText $ pack $ MySQL.connectDatabase connectInfo
           , PersistText $ unDBName $ entityDB def
           , PersistText $ unDBName $ entityID def ]

    helperClmns = CL.mapM getIt C.=$ CL.consume
        where
          getIt = fmap (either Left (Right . Left)) .
                  liftIO .
                  getColumn connectInfo getter (entityDB def)

    helperCntrs = do
      let check [PersistText cntrName, PersistText clmnName] = return (cntrName, clmnName)
          check other = fail $ "helperCntrs: unexpected " ++ show other
      rows <- mapM check =<< CL.consume
      return $ map (Right . Right . (DBName . fst . head &&& map (DBName . snd)))
             $ groupBy ((==) `on` fst) rows


-- | Get the information about a column in a table.
getColumn :: MySQL.ConnectInfo
          -> (Text -> IO Statement)
          -> DBName
          -> [PersistValue]
          -> IO (Either Text Column)
getColumn connectInfo getter tname [ PersistText cname
                                   , PersistText null_
                                   , PersistText type'
                                   , default'] =
    fmap (either (Left . pack) Right) $
    runErrorT $ do
      -- Default value
      default_ <- case default' of
                    PersistNull   -> return Nothing
                    PersistText t -> return (Just t)
                    _ -> fail $ "Invalid default column: " ++ show default'

      -- Column type
      type_ <- parseType type'

      -- Foreign key (if any)
      stmt <- lift $ getter "SELECT REFERENCED_TABLE_NAME, \
                                   \CONSTRAINT_NAME \
                            \FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE \
                            \WHERE TABLE_SCHEMA = ? \
                              \AND TABLE_NAME   = ? \
                              \AND COLUMN_NAME  = ? \
                              \AND REFERENCED_TABLE_SCHEMA = ? \
                            \ORDER BY CONSTRAINT_NAME, \
                                     \COLUMN_NAME"
      let vars = [ PersistText $ pack $ MySQL.connectDatabase connectInfo
                 , PersistText $ unDBName $ tname
                 , PersistText $ cname
                 , PersistText $ pack $ MySQL.connectDatabase connectInfo ]
      cntrs <- C.runResourceT $ withStmt stmt vars C.$$ CL.consume
      ref <- case cntrs of
               [] -> return Nothing
               [[PersistText tab, PersistText ref]] ->
                   return $ Just (DBName tab, DBName ref)
               _ -> fail "MySQL.getColumn/getRef: never here"

      -- Okay!
      return $ Column (DBName cname) (null_ == "YES") type_ default_ ref

getColumn _ _ _ x =
    return $ Left $ pack $ "Invalid result from INFORMATION_SCHEMA: " ++ show x


-- | Parse the type of column as returned by MySQL's
-- @INFORMATION_SCHEMA@ tables.
parseType :: Monad m => Text -> m SqlType
parseType "tinyint"    = return SqlBool
-- Ints
parseType "int"        = return SqlInt32
parseType "short"      = return SqlInt32
parseType "long"       = return SqlInteger
parseType "longlong"   = return SqlInteger
parseType "mediumint"  = return SqlInt32
parseType "bigint"     = return SqlInteger
-- Double
parseType "float"      = return SqlReal
parseType "double"     = return SqlReal
parseType "decimal"    = return SqlReal
parseType "newdecimal" = return SqlReal
-- Text
parseType "varchar"    = return SqlString
parseType "varstring"  = return SqlString
parseType "string"     = return SqlString
parseType "text"       = return SqlString
parseType "tinytext"   = return SqlString
parseType "mediumtext" = return SqlString
parseType "longtext"   = return SqlString
-- ByteString
parseType "blob"       = return SqlBlob
parseType "tinyblob"   = return SqlBlob
parseType "mediumblob" = return SqlBlob
parseType "longblob"   = return SqlBlob
-- Time-related
parseType "time"       = return SqlTime
parseType "datetime"   = return SqlDayTime
parseType "timestamp"  = return SqlDayTime
parseType "date"       = return SqlDay
parseType "newdate"    = return SqlDay
parseType "year"       = return SqlDay
-- Unsupported
parseType other        = fail $ "MySQL.parseType: type " ++
                                show other ++ " not supported."


----------------------------------------------------------------------


-- | @getAlters allDefs tblName new old@ finds out what needs to
-- be changed from @old@ to become @new@.
getAlters :: [EntityDef]
          -> DBName
          -> ([Column], [(DBName, [DBName])])
          -> ([Column], [(DBName, [DBName])])
          -> ([AlterColumn'], [AlterTable])
getAlters allDefs tblName (c1, u1) (c2, u2) =
    (getAltersC c1 c2, getAltersU u1 u2)
  where
    getAltersC [] old = map (\x -> (cName x, Drop)) old
    getAltersC (new:news) old =
        let (alters, old') = findAlters allDefs new old
         in alters ++ getAltersC news old'

    getAltersU [] old = map (DropUniqueConstraint . fst) old
    getAltersU ((name, cols):news) old =
        case lookup name old of
            Nothing ->
                AddUniqueConstraint name (map findType cols) : getAltersU news old
            Just ocols ->
                let old' = filter (\(x, _) -> x /= name) old
                 in if sort cols == ocols
                        then getAltersU news old'
                        else  DropUniqueConstraint name
                            : AddUniqueConstraint name (map findType cols)
                            : getAltersU news old'
        where
          findType = findTypeOfColumn allDefs tblName


-- | @findAlters newColumn oldColumns@ finds out what needs to be
-- changed in the columns @oldColumns@ for @newColumn@ to be
-- supported.
findAlters :: [EntityDef] -> Column -> [Column] -> ([AlterColumn'], [Column])
findAlters allDefs col@(Column name isNull type_ def ref) cols =
    case filter ((name ==) . cName) cols of
        [] -> ( let cnstr = [addReference allDefs tname | Just (tname, _) <- [ref]]
                in map ((,) name) (Add col : cnstr)
              , cols )
        Column _ isNull' type_' def' ref':_ ->
            let -- Foreign key
                refDrop = case (ref == ref', ref') of
                            (False, Just (_, cname)) -> [(name, DropReference cname)]
                            _ -> []
                refAdd  = case (ref == ref', ref) of
                            (False, Just (tname, _)) -> [(name, addReference allDefs tname)]
                            _ -> []
                -- Type and nullability
                modType | type_ == type_' && isNull == isNull' = []
                        | otherwise = [(name, Change col)]
                -- Default value
                modDef | def == def' = []
                       | otherwise   = case def of
                                         Nothing -> [(name, NoDefault)]
                                         Just s -> [(name, Default $ T.unpack s)]
            in ( refDrop ++ modType ++ modDef ++ refAdd
               , filter ((name /=) . cName) cols )


----------------------------------------------------------------------


-- | Prints the part of a @CREATE TABLE@ statement about a given
-- column.
showColumn :: Column -> String
showColumn (Column n nu t def ref) = concat
    [ escapeDBName n
    , " "
    , showSqlType t
    , " "
    , if nu then "NULL" else "NOT NULL"
    , case def of
        Nothing -> ""
        Just s -> " DEFAULT " ++ T.unpack s
    , case ref of
        Nothing -> ""
        Just (s, _) -> " REFERENCES " ++ escapeDBName s
    ]


-- | Renders an 'SqlType' in MySQL's format.
showSqlType :: SqlType -> String
showSqlType SqlBlob    = "BLOB"
showSqlType SqlBool    = "TINYINT(1)"
showSqlType SqlDay     = "DATE"
showSqlType SqlDayTime = "DATETIME"
showSqlType SqlInt32   = "INT"
showSqlType SqlInteger = "BIGINT"
showSqlType SqlReal    = "DOUBLE PRECISION"
showSqlType SqlString  = "VARCHAR(65535)"
showSqlType SqlTime    = "TIME"


-- | Render an action that must be done on the database.
showAlterDb :: AlterDB -> (Bool, Text)
showAlterDb (AddTable s) = (False, pack s)
showAlterDb (AlterColumn t (c, ac)) =
    (isUnsafe ac, pack $ showAlter t (c, ac))
  where
    isUnsafe Drop = True
    isUnsafe _    = False
showAlterDb (AlterTable t at) = (False, pack $ showAlterTable t at)


-- | Render an action that must be done on a table.
showAlterTable :: DBName -> AlterTable -> String
showAlterTable table (AddUniqueConstraint cname cols) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD CONSTRAINT "
    , escapeDBName cname
    , " UNIQUE("
    , intercalate "," $ map escapeDBName' cols
    , ")"
    ]
    where
      escapeDBName' (name, (FieldType "String")) = escapeDBName name ++ "(200)"
      escapeDBName' (name, _                   ) = escapeDBName name
showAlterTable table (DropUniqueConstraint cname) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP INDEX "
    , escapeDBName cname
    ]


-- | Render an action that must be done on a column.
showAlter :: DBName -> AlterColumn' -> String
showAlter table (n, Change col) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " CHANGE "
    , escapeDBName n
    , showColumn col
    ]
showAlter table (_, Add col) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD COLUMN "
    , showColumn col
    ]
showAlter table (n, Drop) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP COLUMN "
    , escapeDBName n
    ]
showAlter table (n, Default s) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ALTER COLUMN "
    , escapeDBName n
    , " SET DEFAULT "
    , s
    ]
showAlter table (n, NoDefault) =
    concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ALTER COLUMN "
    , escapeDBName n
    , " DROP DEFAULT"
    ]
showAlter table (n, Update s) =
    concat
    [ "UPDATE "
    , escapeDBName table
    , " SET "
    , escapeDBName n
    , "="
    , s
    , " WHERE "
    , escapeDBName n
    , " IS NULL"
    ]
showAlter table (n, AddReference t2 id2) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " ADD CONSTRAINT "
    , escapeDBName $ refName table n
    , " FOREIGN KEY("
    , escapeDBName n
    , ") REFERENCES "
    , escapeDBName t2
    , "("
    , escapeDBName id2
    , ")"
    ]
showAlter table (_, DropReference cname) = concat
    [ "ALTER TABLE "
    , escapeDBName table
    , " DROP CONSTRAINT "
    , escapeDBName cname
    ]

refName :: DBName -> DBName -> DBName
refName (DBName table) (DBName column) =
    DBName $ T.concat [table, "_", column, "_fkey"]


----------------------------------------------------------------------


-- | Escape a database name to be included on a query.
--
-- FIXME: Can we do better here?
escapeDBName :: DBName -> String
escapeDBName (DBName s) = T.unpack s

-- | Information required to connect to a MySQL database
-- using @persistent@'s generic facilities.  These values are the
-- same that are given to 'withMySQLPool'.
data MySQLConf = MySQLConf
    { myConnInfo :: MySQL.ConnectInfo
      -- ^ The connection information.
    , myPoolSize :: Int
      -- ^ How many connections should be held on the connection pool.
    }


instance PersistConfig MySQLConf where
    type PersistConfigBackend MySQLConf = SqlPersist

    type PersistConfigPool    MySQLConf = ConnectionPool

    createPoolConfig (MySQLConf cs size) = createMySQLPool cs size

    runPool _ = runSqlPool

    loadConfig (Object o) = do
        database <- o .: "database"
        host     <- o .: "host"
        port     <- o .: "port"
        user     <- o .: "user"
        password <- o .: "password"
        pool     <- o .: "poolsize"
        let ci = MySQL.defaultConnectInfo
                   { MySQL.connectHost     = host
                   , MySQL.connectPort     = port
                   , MySQL.connectUser     = user
                   , MySQL.connectPassword = password
                   , MySQL.connectDatabase = database
                   }
        return $ MySQLConf ci pool
    loadConfig _ = mzero

    applyEnv conf = do
        env <- getEnvironment
        let maybeEnv old var = maybe old id $ lookup ("MYSQL_" ++ var) env
        return conf
          { myConnInfo =
              case myConnInfo conf of
                MySQL.ConnectInfo
                  { MySQL.connectHost     = host
                  , MySQL.connectPort     = port
                  , MySQL.connectUser     = user
                  , MySQL.connectPassword = password
                  , MySQL.connectDatabase = database
                  } -> (myConnInfo conf)
                         { MySQL.connectHost     = maybeEnv host "HOST"
                         , MySQL.connectPort     = read $ maybeEnv (show port) "PORT"
                         , MySQL.connectUser     = maybeEnv user "USER"
                         , MySQL.connectPassword = maybeEnv password "PASSWORD"
                         , MySQL.connectDatabase = maybeEnv database "DATABASE"
                         }
          }
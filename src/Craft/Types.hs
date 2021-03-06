{-# LANGUAGE DeriveFunctor #-}
module Craft.Types where

import Control.Lens
import Control.Monad.Free
import Control.Monad.Logger (Loc, LogSource, LogLevel(..), LogStr)
import Control.Monad.Reader
import Control.Monad.Except
import Data.ByteString (ByteString)
import qualified Data.Text as T
import Data.Versions (parseV)
import System.Process

import Craft.Helpers


type Craft a = ExceptT String (ReaderT CraftEnv (Free CraftDSL)) a


type StdOut = String
type StdErr = String
type Args = [String]
type Command = FilePath


data Watched
  = Unchanged
  | Created
  | Updated
  | Removed
  deriving (Eq, Show)


data SuccResult = SuccResult { _stdout   :: StdOut
                             , _stderr   :: StdErr
                             , _succProc :: CreateProcess
                             }


data FailResult = FailResult { _exitcode   :: Int
                             , _failStdout :: StdOut
                             , _failStderr :: StdErr
                             , _failProc   :: CreateProcess
                             }

data ExecResult = ExecFail FailResult | ExecSucc SuccResult

type ExecEnv = [(String, String)]
type CWD = FilePath

type PackageName = String


data Version
  = Version String
  | AnyVersion
  | Latest
  deriving (Show)


-- Note: This may or may not make sense.
-- Open to suggestions if any of this seems incorrect.
instance Eq Version where
  (==) AnyVersion  _           = True
  (==) _           AnyVersion  = True
  (==) Latest      Latest      = True
  (==) Latest      (Version _) = False
  (==) (Version _) Latest      = False
  (==) (Version a) (Version b) = a == b


data Package =
  Package
  { _pkgName    :: PackageName
  , _pkgVersion :: Version
  }
  deriving (Eq, Show)


data PackageManager
 = PackageManager
   { _pmGetter         :: PackageName -> Craft (Maybe Package)
   , _pmInstaller      :: Package     -> Craft ()
   , _pmUpgrader       :: Package     -> Craft ()
   , _pmUninstaller    :: Package     -> Craft ()
   , _pmMultiInstaller :: [Package]   -> Craft ()
   }


data CraftEnv
  = CraftEnv
    { _craftPackageManager :: PackageManager
    , _craftSourcePaths    :: [FilePath]
    , _craftExecEnv        :: ExecEnv
    , _craftExecCWD        :: FilePath
    , _craftLogger         :: LogFunc
    }


data CraftDSL next
  = Exec  CraftEnv Command Args (ExecResult -> next)
  | Exec_ CraftEnv Command Args next
  | FileRead CraftEnv FilePath (ByteString -> next)
  | FileWrite CraftEnv FilePath ByteString next
  | SourceFile CraftEnv FilePath FilePath next
  | FindSourceFile CraftEnv FilePath ([FilePath] -> next)
  | ReadSourceFile CraftEnv FilePath (ByteString -> next)
  | Log CraftEnv Loc LogSource LogLevel LogStr next
 deriving Functor


type LogFunc = Loc -> LogSource -> LogLevel -> LogStr -> IO ()


makeLenses ''PackageManager
makeLenses ''CraftEnv
makePrisms ''Watched
makeLenses ''Package
makePrisms ''Version
makeLenses ''FailResult
makeLenses ''SuccResult


class Craftable a where
  watchCraft :: a -> Craft (Watched, a)

  craft :: a -> Craft a
  craft x = snd <$> watchCraft x

  craft_ :: a -> Craft ()
  craft_ = void . craft

  watchCraft_ :: a -> Craft Watched
  watchCraft_ x = fst <$> watchCraft x

  {-# MINIMAL watchCraft #-}

class Destroyable a where
  watchDestroy :: a -> Craft (Watched, Maybe a)

  destroy :: a -> Craft (Maybe a)
  destroy x = snd <$> watchDestroy x

  destroy_ :: a -> Craft ()
  destroy_ = void . destroy

  watchDestroy_ :: a -> Craft Watched
  watchDestroy_ x = fst <$> watchDestroy x

  {-# MINIMAL watchDestroy #-}


execResultProc :: ExecResult -> CreateProcess
execResultProc (ExecFail failr) = failr ^. failProc
execResultProc (ExecSucc succr) = succr ^. succProc


instance Show FailResult where
  show r = concatMap appendNL [ "exec failed!"
                              , "<<<< process >>>>"
                              , showProc (r ^. failProc)
                              , "<<<< exit code >>>>"
                              , show (r ^. exitcode)
                              , "<<<< stdout >>>>"
                              , r ^. failStdout
                              , "<<<< stderr >>>>"
                              , r ^. failStderr
                              ]



showProc :: CreateProcess -> String
showProc p =
  case cmdspec p of
    ShellCommand s -> s
    RawCommand fp args -> unwords [fp, unwords args]


instance Ord Version where
  compare AnyVersion  AnyVersion  = EQ
  compare AnyVersion  Latest      = LT
  compare AnyVersion  (Version _) = EQ
  compare Latest      AnyVersion  = GT
  compare Latest      Latest      = EQ
  compare Latest      (Version _) = GT
  compare (Version _) AnyVersion  = EQ
  compare (Version _) Latest      = LT
  compare (Version a) (Version b) = compareVersions a b

compareVersions :: String -> String -> Ordering
compareVersions a b = compare (ver a) (ver b)
 where
  ver x = case parseV (T.pack x) of
            Left err -> error $ "Failed to parse version '" ++ x ++ "': "
                                ++ show err
            Right v -> v

package :: PackageName -> Package
package n = Package n AnyVersion

latest :: PackageName -> Package
latest n = Package n Latest


instance Craftable Package where
  watchCraft pkg = do
    ce <- ask
    let pm = ce ^. craftPackageManager
        name = pkg ^. pkgName
        ver  = pkg ^. pkgVersion
        get  = (pm ^. pmGetter) name
        install = (pm ^. pmInstaller) pkg
        upgrade = (pm ^. pmUpgrader) pkg
        error' str = error $ "craft Package `" ++ name ++ "` failed! " ++ str
        notFound = error' "Not Found."
        wrongVersion got = error' $ "Wrong Version: " ++ show got
                                    ++ " Excepted: " ++ show ver
    get >>= \case -- Figure out what to do.
      Nothing -> do
        install -- It's not installed. Install it.
        get >>= \case -- Verify the installation.
          Nothing -> notFound -- Not Found. The install failed.
          Just pkg' -> do -- It worked!
            let ver' = pkg' ^. pkgVersion
                ok   = return (Created, pkg')
            case ver of -- Ensure the correct version was installed.
              AnyVersion -> ok
              Latest     -> ok
              Version  _ ->
                if ver == ver' then
                  ok
                else
                  wrongVersion ver'
      Just pkg' -> do -- It was already installed.
        let ver' = pkg' ^. pkgVersion
        case ver of
          AnyVersion -> return (Unchanged, pkg')
          Latest -> do
            upgrade -- Ensure it's the latest version.
            get >>= \case
              Nothing -> notFound -- Where did it go?
              Just pkg'' -> do
                let ver'' = pkg'' ^. pkgVersion
                if ver'' > ver' then
                  return (Updated, pkg'') -- Upgrade complete.
                else
                  return (Unchanged, pkg'') -- Already the latest.
          Version _ -> -- Expecting a specific version
            if ver == ver' then
              return (Unchanged, pkg')
            else do
              upgrade -- Try upgrading to the correct version.
              get >>= \case
                Nothing -> notFound -- Where did it go?
                Just pkg'' -> do
                  let ver'' = pkg'' ^. pkgVersion
                  if ver'' == ver then
                    return (Updated, pkg'')
                  else
                    wrongVersion ver''


instance Destroyable Package where
  watchDestroy pkg = do
    ce <- ask
    let pm   = ce ^. craftPackageManager
        name = pkg ^. pkgName
        get  = (pm ^. pmGetter) name
    get >>= \case
      Nothing -> return (Unchanged, Nothing)
      Just pkg' -> do
        (pm ^. pmUninstaller) pkg
        get >>= \case
          Nothing -> return (Removed, Just pkg')
          Just pkg'' -> error $ "destroy Package `" ++ name ++ "` failed! "
                                ++ "Found: " ++ show pkg''


changed :: Watched -> Bool
changed = not . unchanged


unchanged :: Watched -> Bool
unchanged Unchanged = True
unchanged _         = False


created :: Watched -> Bool
created Created = True
created _       = False


updated :: Watched -> Bool
updated Updated = True
updated _       = False


removed :: Watched -> Bool
removed Removed = True
removed _       = False

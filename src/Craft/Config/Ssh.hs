module Craft.Config.Ssh where

import Control.Lens hiding (noneOf)
import           Data.Char (toLower)
import           Data.Maybe (catMaybes)
import           Text.Megaparsec

import Craft
import Craft.Config
import qualified Craft.Directory as Directory
import           Craft.File (file)
import qualified Craft.File as File
import           Craft.File.Mode
import           Craft.Internal.Helpers
import           Craft.Ssh
import           Craft.User (User)
import qualified Craft.User as User


data Section
  = Host  String Body
  | Match String Body
  deriving Eq


type Sections = [Section]


type Body = [(String, String)]


newtype SshConfig = SshConfig { _sshfmt :: Sections }
  deriving Eq


instance Show SshConfig where
  show sshcfg = unlines . map show $ _sshfmt sshcfg


data UserConfig
  = UserConfig
    { _user        :: User
    , _userConfigs :: SshConfig
    }
  deriving Eq
makeLenses ''SshConfig
makeLenses ''UserConfig

instance ConfigFormat SshConfig where
  showConfig = show
  parse = sshConfigParse


userPath :: UserConfig -> FilePath
userPath uc = userDir (uc ^. user) ^. Directory.path </> "config"


get :: FilePath -> Craft (Maybe (Config SshConfig))
get fp =
  File.get fp >>= \case
    Nothing -> return Nothing
    Just f  -> Just <$> configFromFile f


bodyLookup :: String -> Body -> Maybe String
bodyLookup key body =
  lookup (map toLower key) $ map ((,) <$> map toLower . fst <*> snd) body


cfgLookup :: String -> String -> SshConfig -> Maybe String
cfgLookup sectionName key (SshConfig sections') =
  case body of
    Just b -> bodyLookup key b
    Nothing -> Nothing
 where
  body = maybeHead . catMaybes $ map f sections'
  f (Host name b) | name == sectionName = Just b
                  | otherwise           = Nothing
  f             _                       = Nothing
  maybeHead []    = Nothing
  maybeHead (x:_) = Just x


instance Craftable UserConfig where
  watchCraft cfg = do
    craft_ $ userDir $ cfg ^. user
    w <- watchCraft_ $ file (userPath cfg)
                         & File.mode .~ Mode RW O O
                         & File.ownerID .~ cfg ^. user . User.uid
                         & File.groupID .~ cfg ^. user . User.gid
                         & File.strContent .~ show cfg
    return (w, cfg)


sshConfigParse :: FilePath -> String -> Craft SshConfig
sshConfigParse fp s =
  case runParser parser fp s of
    Left err   -> $craftError $ show err
    Right secs -> return $ SshConfig secs


instance Show UserConfig where
  show uc = show $ uc ^. userConfigs


showBody :: Body -> String
showBody body = indent 4 . unlines $ map (\(n, v) -> n ++ " " ++ v) body


instance Show Section where
  show (Host hostname body)  = "Host " ++ hostname ++ "\n" ++ showBody body
  show (Match match body)    = "Match " ++ match ++ "\n" ++ showBody body


parseTitle :: Parsec String (String, String)
parseTitle = do
  space
  type' <- try (string' "host") <|> string' "match"
  void spaceChar
  notFollowedBy eol
  space
  name <- anyChar `someTill` eol
  return (type', name)


parseBody :: Parsec String [(String, String)]
parseBody = many bodyLine


bodyLine :: Parsec String (String, String)
bodyLine = do
  notFollowedBy parseTitle
  space
  name <- someTill anyChar spaceChar
  notFollowedBy eol
  space
  val <- between (char '"') (char '"') (many $ noneOf "\"")
         <|> someTill anyChar (void eol <|> eof)
  void $ optional (space <|> void (many eol))
  return (name, trim val)


parseSection :: Parsec String Section
parseSection = do
  title <- parseTitle
  body <- parseBody
  return $ case map toLower (fst title) of
    "host"  -> Host (snd title) body
    "match" -> Match (snd title) body
    _       -> error "Craft.Config.Ssh.parse failed. This should be impossible."


parser :: Parsec String Sections
parser = some parseSection


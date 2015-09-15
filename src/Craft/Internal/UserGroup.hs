module Craft.Internal.UserGroup
( module Craft.Internal.UserGroup
, UserID
, GroupID
)
where

import           Craft
import           Craft.Internal.Helpers

import           Control.Exception (tryJust)
import           Control.Monad (guard)
import           Control.Monad.IO.Class (liftIO)
import           Data.List (intercalate)
import           Data.Maybe (catMaybes)
import           System.IO.Error (isDoesNotExistError)
import           System.Posix

type UserName = String

data User
  = Root
  | User
    { username     :: UserName
    , uid          :: UserID
    , comment      :: String
    , group        :: Group
    , groups       :: [GroupName]
    , home         :: FilePath
    , passwordHash :: String
    --, salt         :: String
    --, locked       :: Bool
    , shell        :: FilePath
    --, system       :: Bool
    }
 deriving (Eq, Show)

userFromName :: UserName -> Craft (Maybe User)
userFromName un = do
  eue <- liftIO $ tryJust (guard . isDoesNotExistError)
                      (getUserEntryForName un)
  case eue of
    Left  _  -> return Nothing
    Right ue -> Just <$> userEntryToUser ue

userFromID :: UserID -> Craft (Maybe User)
userFromID ui = do
  eue <- liftIO $ tryJust (guard . isDoesNotExistError)
                      (getUserEntryForID ui)
  case eue of
    Left  _  -> return Nothing
    Right ue -> Just <$> userEntryToUser ue

userEntryToUser :: UserEntry -> Craft User
userEntryToUser ue =
  groupFromID (userGroupID ue) >>= \case
    Nothing -> error $
      "User `" ++ userName ue ++ "` found, "
      ++ "but user's group does not exist!"
    Just g -> do
      let un = userName ue
      gs <- mapM groupFromName =<< memberOf un
      return
        User { username = un
             , uid = userID ue
             , group = g
             , groups = groupname <$> catMaybes gs
             , passwordHash = userPassword ue
             , home = homeDirectory ue
             , shell = userShell ue
             , comment = userGecos ue
             }


memberOf :: UserName -> Craft [GroupName]
memberOf un = do
  ges <- liftIO getAllGroupEntries
  return $ groupName <$> filter (elem un . groupMembers) ges

instance Craftable User where
  checker = userFromName . username

  crafter Root = return ()
  crafter user@User{..} = do
    liftIO $ msg "create" $ show user
    g <- groupFromName (groupname group) >>= \case
      Nothing -> craft group
      Just g  -> return g
    exec_ "/usr/sbin/useradd" $ args ++ toArg "--gid" (gid g)
   where
    args = Prelude.concat
      [ toArg "--uid"         uid
      , toArg "--comment"     comment
      , toArg "--groups"      $ intercalate "," groups
      , toArg "--home"        home
      , toArg "--password"    passwordHash
      , toArg "--shell"       shell
      ]

  remover _ = notImplemented "remover User"

type GroupName = String

toGroupName :: GroupID -> Craft GroupName
toGroupName i = liftIO $ groupName <$> getGroupEntryForID i

data Group
  = RootGroup
  | Group
    { groupname :: GroupName
    , gid       :: GroupID
    , members   :: [UserName]
    }
  deriving (Eq, Show)

groupFromName :: GroupName -> Craft (Maybe Group)
groupFromName gn = do
  ege <- liftIO $ tryJust (guard . isDoesNotExistError)
                      (getGroupEntryForName gn)
  case ege of
    Left  _  -> return Nothing
    Right ge -> return . Just $ groupEntryToGroup ge

groupFromID :: GroupID -> Craft (Maybe Group)
groupFromID gi = do
  ege <- liftIO $ tryJust (guard . isDoesNotExistError)
                      (getGroupEntryForID gi)
  case ege of
    Left  _  -> return Nothing
    Right ge -> return . Just $ groupEntryToGroup ge

groupEntryToGroup :: GroupEntry -> Group
groupEntryToGroup ge =
  Group { groupname = groupName ge
        , gid       = groupID ge
        , members   = groupMembers ge
        }

instance Craftable Group where
  checker = groupFromName . groupname

  crafter RootGroup = return ()
  crafter g@Group{..} = do
    liftIO $ msg "create" $ show g
    exec_ "/usr/sbin/groupadd" $ toArg "--gid" gid ++ [groupname]
    exec_  "/usr/bin/gpasswd" ["--members", intercalate "," members, groupname]

  remover _ = notImplemented "remover Group"
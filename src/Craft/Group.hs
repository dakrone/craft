module Craft.Group
( module Craft.Group
, Group(..)
, GroupID
)
where

import           Control.Monad.IO.Class (liftIO)
import           Data.List (intercalate)

import           Craft
import           Craft.Internal.Helpers
import           Craft.Internal.UserGroup

type Name = GroupName

name :: Group -> Name
name = groupname

root :: Group
root = RootGroup

data Options =
  Options
  { optGID :: Maybe GroupID
  , optAllowdupe :: Bool
  , optUsers :: [UserName]
  , optSystem :: Bool
  }

opts :: Options
opts =
  Options
  { optGID       = Nothing
  , optAllowdupe = False
  , optUsers     = []
  , optSystem    = False
  }

createGroup :: Name -> Options -> Craft Group
createGroup gn Options{..} = do
  liftIO $ msg "Group.createGroup" gn
  exec_ "/usr/sbin/groupadd" args
  exec_ "/usr/bin/gpasswd" ["--members", intercalate "," optUsers, gn]
  fromName gn >>= \case
    Nothing -> error $ "createGroup `" ++ show gn ++ "` failed. Not Found!"
    Just g -> return g
 where
  args = concat
   [ toArg "--gid"        optGID
   , toArg "--non-unique" optAllowdupe
   , toArg "--system"     optSystem
   ]

fromName :: Name -> Craft (Maybe Group)
fromName = groupFromName

fromID :: GroupID -> Craft (Maybe Group)
fromID = groupFromID

idToName :: GroupID -> Craft GroupName
idToName = toGroupName
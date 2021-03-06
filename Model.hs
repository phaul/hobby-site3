{-# LANGUAGE FlexibleInstances #-}

module Model where

import Prelude
import Yesod
import qualified Yesod.Auth.HashDB as HDB
import Data.Text (Text)
import Data.Monoid
import Data.Time.Clock
import Data.Int
import Data.Maybe
import Control.Monad
import Database.Persist.Quasi
import Database.Persist.Store
import Database.Persist.GenericSql
import Lib.Accessibility


-- You can define all of your database entities in the entities file.
-- You can find more information on persistent and how to declare entities
-- at:
-- http://www.yesodweb.com/book/persistent/
share
   [ mkPersist sqlOnlySettings
   , mkMigrate "migrateAll"
   , mkDeleteCascade sqlOnlySettings
   ] $(persistFileWith lowerCaseSettings "config/models")


instance (PathPiece t) => PathPiece (Maybe t) where
   toPathPiece (Just galleryId) = toPathPiece galleryId
   toPathPiece Nothing          = "nothing"
   fromPathPiece "nothing"      = Nothing
   fromPathPiece text           = Just $ fromPathPiece text


instance HDB.HashDBUser (User) where
  userPasswordHash = Just . userHash
  userPasswordSalt = Just . userSalt 
  setSaltAndPasswordHash s h u = u { userHash = h
                                   , userSalt = s
                                   }


-- naming convetions here just follows the normal rules as these were normal
-- Entity fields

-- | the images directly inside an ImageGallery
galleryImages ::
   ( YesodPersist master
   , PersistQuery (YesodPersistBackend master (GHandler sub master))
   , PersistMonadBackend (YesodPersistBackend master (GHandler sub master)) ~ PersistEntityBackend Image
   , YesodPersistBackend master ~ SqlPersist
   )
   => GalleryId -- ^ id of the gallery in which we inspect the contained images 
   -> GHandler sub master [Entity Image]
galleryImages galleryId = runDB $ rawSql query [ toPersistValue galleryId ]
   where
      query = "SELECT ?? FROM image, image_gallery WHERE image_gallery.image_id = image.id AND image_gallery.gallery_id = ?"


-- | the children galleries of a Gallery
galleryChildren :: 
   ( YesodPersist master
   , PersistQuery (YesodPersistBackend master (GHandler sub master))
   , PersistMonadBackend (YesodPersistBackend master (GHandler sub master)) ~ PersistEntityBackend Gallery
   )
   => Maybe GalleryId      -- ^ id of the gallery in which we query the siblings
   -> [SelectOpt Gallery]  -- ^ query options
   -> GHandler sub master [Entity Gallery]
galleryChildren mGalleryId = runDB . selectList [ GalleryParentId ==. mGalleryId ]


-- a representative thumbnail for the gallery ( if any )
galleryThumbnail ::
   ( YesodPersist master
   , PersistQuery (YesodPersistBackend master (GHandler sub master))
   , PersistMonadBackend (YesodPersistBackend master (GHandler sub master)) ~ PersistEntityBackend Image
   , YesodPersistBackend master ~ SqlPersist
   )
   => Maybe UserId -- ^ user currently logged in
   -> GalleryId    -- ^ id of the gallery in which we inspect the contained images 
   -> GHandler sub master (Maybe (Entity Image))
galleryThumbnail mUserId galleryId =
   runDB $ liftM listToMaybe $ rawSql query $ toPersistValue galleryId : imageAccess mUserId
   where
      query = "WITH RECURSIVE children_gallery_ids(id) AS "
            -- recursion entry, fills up the working table
            <> "( "
            <> "   SELECT id FROM gallery WHERE id = ? "
            <> "UNION ALL "
            -- recursion, working table has data from previous level
            <> "   SELECT gallery.id "
            <> "     FROM children_gallery_ids, gallery "
            <> "     WHERE gallery.parent_id=children_gallery_ids.id "
            <> ") SELECT ?? FROM children_gallery_ids "
            <> "JOIN image_gallery ON children_gallery_ids.id = image_gallery.gallery_id "
            <> "JOIN image ON image_gallery.image_id = image.id "
            <> imageAccessSql mUserId
            <> "ORDER BY random() LIMIT 1"
      imageAccess (Just userId) = map toPersistValue [ Public, Member ] ++ [ toPersistValue userId ]
      imageAccess Nothing       = [ toPersistValue Public ]
      imageAccessSql (Just _)   = "WHERE image.accessibility = ? OR image.accessibility = ? OR image.user_id = ? "
      imageAccessSql Nothing    = "WHERE image.accessibility = ? "


galleryNames ::
   ( YesodPersist master
   , YesodPersistBackend master ~ SqlPersist
   )
   => Entity User
   -> Text
   -> GHandler sub master [ Entity Gallery ]
galleryNames (Entity userId user) query = do
   let name = toPersistValue $ "%" <> query <> "%"
   let (userSql, userPersist) = if userAdmin user
         then ("", [])
         else (" AND user_id = ?", [ toPersistValue userId ])
   let sqlQuery = "SELECT ?? FROM gallery WHERE name LIKE ?" <> userSql <> " ORDER BY name"
   runDB $ rawSql sqlQuery $ name : userPersist


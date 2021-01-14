{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Plugin where

import Data.Dependent.Map (DMap)
import qualified Data.Dependent.Map as DMap
import Data.Dependent.Sum (DSum (..))
import qualified Data.Map.Strict as Map
import Data.Some (Some (..), withSome)
import qualified Data.Text as T
import Neuron.Frontend.Route (NeuronWebT)
import Neuron.Frontend.Route.Data.Types
import qualified Neuron.Plugin.Plugins.DirTree as DirTree
import qualified Neuron.Plugin.Plugins.NeuronIgnore as NeuronIgnore
import qualified Neuron.Plugin.Plugins.Tags as Tags
import Neuron.Plugin.Type (Plugin (..))
import Neuron.Zettelkasten.Graph.Type (ZettelGraph)
import Neuron.Zettelkasten.ID (ZettelID)
import Neuron.Zettelkasten.Resolver (ZIDRef)
import Neuron.Zettelkasten.Zettel
import Neuron.Zettelkasten.Zettel.Parser (extractQueriesWithContext, parseZettels)
import Reflex.Dom.Core (DomBuilder, PostBuild)
import Reflex.Dom.Pandoc (PandocBuilder)
import Reflex.Dom.Widget (blank)
import Relude
import qualified System.Directory.Contents.Types as DC

type PluginRegistry = Map (Some PluginZettelData) (Some Plugin)

pluginRegistryShow :: PluginRegistry -> Text
pluginRegistryShow r =
  T.intercalate ", " $
    Map.keys r <&> \case
      Some PluginZettelData_DirTree -> "dirtree"
      Some PluginZettelData_Tags -> "tags"
      Some PluginZettelData_NeuronIgnore -> "neuronignore"

lookupPlugins :: [Text] -> PluginRegistry
lookupPlugins = Map.fromList . mapMaybe lookupPlugin
  where
    lookupPlugin :: Text -> Maybe (Some PluginZettelData, Some Plugin)
    lookupPlugin = \case
      "dirtree" -> Just (Some PluginZettelData_DirTree, Some DirTree.plugin)
      "tags" -> Just (Some PluginZettelData_Tags, Some Tags.plugin)
      "neuronignore" -> Just (Some PluginZettelData_NeuronIgnore, Some NeuronIgnore.plugin)
      _ -> Nothing

filterSources :: PluginRegistry -> DC.DirTree FilePath -> IO (Maybe (DC.DirTree FilePath))
filterSources plugins t = do
  let applyF = Map.elems plugins <&> \sp -> withSome sp _plugin_filterSources
      combiner :: (Traversable m, Monad m) => IO (m a) -> (a -> IO (m b)) -> IO (m b)
      combiner = \ima f -> (fmap join . traverse f) =<< ima
  foldl' combiner (pure $ Just t) applyF

afterZettelParse :: PluginRegistry -> [(ZettelID, (FilePath, (Text, DMap PluginZettelData Identity)))] -> [ZettelC]
afterZettelParse plugins fs = do
  parseZettels extractQueriesWithContext fs <&> \z ->
    foldl' (\z1 f -> f z1) z (plugins <&> \sp -> withSome sp _plugin_afterZettelParse)

afterZettelRead :: MonadState (Map ZettelID ZIDRef) m => PluginRegistry -> DC.DirTree FilePath -> m ()
afterZettelRead plugins fileTree = do
  forM_ (plugins <&> \sp -> withSome sp _plugin_afterZettelRead) $ \f -> f fileTree

routePluginData :: ZettelGraph -> ZettelC -> DSum PluginZettelData Identity -> DSum PluginZettelRouteData Identity
routePluginData g z = \case
  PluginZettelData_DirTree :=> Identity dirTree ->
    PluginZettelRouteData_DirTree :=> Identity (DirTree.routePluginData g dirTree)
  PluginZettelData_Tags :=> Identity dirTree ->
    PluginZettelRouteData_Tags :=> Identity (Tags.routePluginData g z dirTree)
  PluginZettelData_NeuronIgnore :=> Identity () ->
    PluginZettelRouteData_NeuronIgnore :=> Identity ()

renderPluginPanel :: (DomBuilder t m, PostBuild t m) => DSum PluginZettelRouteData Identity -> NeuronWebT t m ()
renderPluginPanel = \case
  PluginZettelRouteData_DirTree :=> Identity t ->
    DirTree.renderPanel t
  PluginZettelRouteData_Tags :=> Identity _ ->
    blank
  PluginZettelRouteData_NeuronIgnore :=> Identity () ->
    blank

renderHandleLink ::
  (PandocBuilder t m, PostBuild t m) =>
  DMap PluginZettelRouteData Identity ->
  Text ->
  Maybe (NeuronWebT t m ())
renderHandleLink pluginData x =
  asum $ flip renderHandleLink' x <$> DMap.toList pluginData

renderHandleLink' ::
  (PandocBuilder t m, PostBuild t m) =>
  DSum PluginZettelRouteData Identity ->
  Text ->
  Maybe (NeuronWebT t m ())
renderHandleLink' = \case
  PluginZettelRouteData_DirTree :=> _ ->
    const Nothing
  PluginZettelRouteData_Tags :=> Identity x ->
    Tags.renderHandleLink x
  PluginZettelRouteData_NeuronIgnore :=> _ ->
    const Nothing
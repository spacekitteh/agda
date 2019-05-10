
module Agda.TypeChecking.Monad.Options where

import Prelude hiding (mapM)
import GHC.Stack (HasCallStack, freezeCallStack, callStack)

import Control.Monad.Reader hiding (mapM)
import Control.Monad.Writer
import Control.Monad.State  hiding (mapM)

import Data.Maybe
import Data.Traversable

import System.Directory
import System.FilePath

import Agda.Syntax.Internal
import Agda.Syntax.Common
import Agda.Syntax.Concrete
import {-# SOURCE #-} Agda.TypeChecking.Monad.Debug
import {-# SOURCE #-} Agda.TypeChecking.Errors
import Agda.TypeChecking.Warnings
import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.State
import Agda.TypeChecking.Monad.Benchmark
import {-# SOURCE #-} Agda.Interaction.FindFile
import Agda.Interaction.Options
import qualified Agda.Interaction.Options.Lenses as Lens
import Agda.Interaction.Response
import Agda.Interaction.Library
import Agda.Utils.FileName
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.Pretty
import Agda.Utils.Trie (Trie)
import qualified Agda.Utils.Trie as Trie
import Agda.Utils.Except
import Agda.Utils.Either

import Agda.Utils.Impossible

-- | Sets the pragma options.

setPragmaOptions :: PragmaOptions -> TCM ()
setPragmaOptions opts = do
  stPragmaOptions `modifyTCLens` Lens.mapSafeMode (Lens.getSafeMode opts ||)
  clo <- commandLineOptions
  let unsafe = unsafePragmaOptions opts
--  when (Lens.getSafeMode clo && not (null unsafe)) $ warning $ SafeFlagPragma unsafe
  when (Lens.getSafeMode opts && not (null unsafe)) $ warning $ SafeFlagPragma unsafe
  ok <- liftIO $ runOptM $ checkOpts (clo { optPragmaOptions = opts })
  case ok of
    Left err   -> __IMPOSSIBLE__
    Right opts -> do
      stPragmaOptions `setTCLens` optPragmaOptions opts
      updateBenchmarkingStatus

-- | Sets the command line options (both persistent and pragma options
-- are updated).
--
-- Relative include directories are made absolute with respect to the
-- current working directory. If the include directories have changed
-- (thus, they are 'Left' now, and were previously @'Right' something@),
-- then the state is reset (completely, see setIncludeDirs) .
--
-- An empty list of relative include directories (@'Left' []@) is
-- interpreted as @["."]@.
setCommandLineOptions :: CommandLineOptions -> TCM ()
setCommandLineOptions opts = do
  root <- liftIO (absolute =<< getCurrentDirectory)
  setCommandLineOptions' root opts

setCommandLineOptions'
  :: AbsolutePath
     -- ^ The base directory of relative paths.
  -> CommandLineOptions
  -> TCM ()
setCommandLineOptions' root opts = do
  z <- liftIO $ runOptM $ checkOpts opts
  case z of
    Left err   -> __IMPOSSIBLE__
    Right opts -> do
      incs <- case optAbsoluteIncludePaths opts of
        [] -> do
          opts' <- setLibraryPaths root opts
          let incs = optIncludePaths opts'
          setIncludeDirs incs root
          getIncludeDirs
        incs -> return incs
      modifyTC $ Lens.setCommandLineOptions opts{ optAbsoluteIncludePaths = incs }
      setPragmaOptions (optPragmaOptions opts)
      updateBenchmarkingStatus

libToTCM :: LibM a -> TCM a
libToTCM m = do
  (z, warns) <- liftIO $ runWriterT $ runExceptT m

  unless (null warns) $ warnings $ map LibraryWarning warns
  case z of
    Left s  -> typeError $ GenericDocError s
    Right x -> return x

setLibraryPaths
  :: AbsolutePath
     -- ^ The base directory of relative paths.
  -> CommandLineOptions
  -> TCM CommandLineOptions
setLibraryPaths root o =
  setLibraryIncludes =<< addDefaultLibraries root o

setLibraryIncludes :: CommandLineOptions -> TCM CommandLineOptions
setLibraryIncludes o = do
    let libs = optLibraries o
    installed <- libToTCM $ getInstalledLibraries (optOverrideLibrariesFile o)
    paths     <- libToTCM $ libraryIncludePaths (optOverrideLibrariesFile o) installed libs
    return o{ optIncludePaths = paths ++ optIncludePaths o }

addDefaultLibraries
  :: AbsolutePath
     -- ^ The base directory of relative paths.
  -> CommandLineOptions
  -> TCM CommandLineOptions
addDefaultLibraries root o
  | or [ not $ null $ optLibraries o
       , not $ optUseLibs o
       , optShowVersion o ] = pure o
  | otherwise = do
  (libs, incs) <- libToTCM $ getDefaultLibraries (filePath root) (optDefaultLibs o)
  return o{ optIncludePaths = incs ++ optIncludePaths o, optLibraries = libs }

setOptionsFromPragma :: OptionsPragma -> TCM ()
setOptionsFromPragma ps = do
    opts <- commandLineOptions
    z    <- liftIO $ runOptM (parsePragmaOptions ps opts)
    case z of
      Left err    -> typeError $ GenericError err
      Right opts' -> setPragmaOptions opts'

-- | Disable display forms.
enableDisplayForms :: MonadTCEnv m => m a -> m a
enableDisplayForms =
  localTC $ \e -> e { envDisplayFormsEnabled = True }

-- | Disable display forms.
disableDisplayForms :: MonadTCEnv m => m a -> m a
disableDisplayForms =
  localTC $ \e -> e { envDisplayFormsEnabled = False }

-- | Check if display forms are enabled.
displayFormsEnabled :: MonadTCEnv m => m Bool
displayFormsEnabled = asksTC envDisplayFormsEnabled

-- | Gets the include directories.
--
-- Precondition: 'optAbsoluteIncludePaths' must be nonempty (i.e.
-- 'setCommandLineOptions' must have run).

getIncludeDirs :: HasOptions m => m [AbsolutePath]
getIncludeDirs = do
  incs <- optAbsoluteIncludePaths <$> commandLineOptions
  case incs of
    [] -> __IMPOSSIBLE__
    _  -> return incs

-- | Makes the given directories absolute and stores them as include
-- directories.
--
-- If the include directories change, then the state is reset (completely,
-- except for the include directories and 'stInteractionOutputCallback').
--
-- An empty list is interpreted as @["."]@.

setIncludeDirs :: [FilePath]    -- ^ New include directories.
               -> AbsolutePath  -- ^ The base directory of relative paths.
               -> TCM ()
setIncludeDirs incs root = do
  -- save the previous include dirs
  oldIncs <- getsTC Lens.getAbsoluteIncludePaths

  -- Add the current dir if no include path is given
  incs <- return $ if null incs then ["."] else incs
  -- Make paths absolute
  incs <- return $  map (mkAbsolute . (filePath root </>)) incs

  -- Andreas, 2013-10-30  Add default include dir
  libdir <- liftIO $ defaultLibDir
      -- NB: This is an absolute file name, but
      -- Agda.Utils.FilePath wants to check absoluteness anyway.
  let primdir = mkAbsolute $ libdir </> "prim"
      -- We add the default dir at the end, since it is then
      -- printed last in error messages.
      -- Might also be useful to overwrite default imports...
  incs <- return $ incs ++ [primdir]

  reportSDoc "setIncludeDirs" 10 $ return $ vcat
    [ "Old include directories:"
    , nest 2 $ vcat $ map pretty oldIncs
    , "New include directories:"
    , nest 2 $ vcat $ map pretty incs
    ]

  -- Check whether the include dirs have changed.  If yes, reset state.
  -- Andreas, 2013-10-30 comments:
  -- The logic, namely using the include-dirs variable as a driver
  -- for the interaction, qualifies for a code-obfuscation contest.
  -- I guess one Boolean more in the state cost 10.000 EUR at the time
  -- of this implementation...
  --
  -- Andreas, perhaps you have misunderstood something: If the include
  -- directories have changed and we do not reset the decoded modules,
  -- then we might (depending on how the rest of the code works) end
  -- up in a situation in which we use the contents of the file
  -- "old-path/M.agda", when the user actually meant
  -- "new-path/M.agda".
  when (oldIncs /= incs) $ do
    ho <- getInteractionOutputCallback
    tcWarnings <- useTC stTCWarnings -- restore already generated warnings
    resetAllState
    setTCLens stTCWarnings tcWarnings
    setInteractionOutputCallback ho

  Lens.putAbsoluteIncludePaths incs

setInputFile :: FilePath -> TCM ()
setInputFile file =
    do  opts <- commandLineOptions
        setCommandLineOptions $
          opts { optInputFile = Just file }

-- | Should only be run if 'hasInputFile'.
getInputFile :: TCM AbsolutePath
getInputFile = fromMaybeM __IMPOSSIBLE__ $
  getInputFile'

-- | Return the 'optInputFile' as 'AbsolutePath', if any.
getInputFile' :: TCM (Maybe AbsolutePath)
getInputFile' = mapM (liftIO . absolute) =<< do
  optInputFile <$> commandLineOptions

hasInputFile :: HasOptions m => m Bool
hasInputFile = isJust <$> optInputFile <$> commandLineOptions

isPropEnabled :: HasOptions m => m Bool
isPropEnabled = optProp <$> pragmaOptions

{-# SPECIALIZE hasUniversePolymorphism :: TCM Bool #-}
hasUniversePolymorphism :: HasOptions m => m Bool
hasUniversePolymorphism = optUniversePolymorphism <$> pragmaOptions

enableCaching :: HasOptions m => m Bool
enableCaching = optCaching <$> pragmaOptions

showImplicitArguments :: HasOptions m => m Bool
showImplicitArguments = optShowImplicit <$> pragmaOptions

showIrrelevantArguments :: HasOptions m => m Bool
showIrrelevantArguments = optShowIrrelevant <$> pragmaOptions

-- | Switch on printing of implicit and irrelevant arguments.
--   E.g. for reification in with-function generation.
--
--   Restores all 'PragmaOptions' after completion.
--   Thus, do not attempt to make persistent 'PragmaOptions'
--   changes in a `withShowAllArguments` bracket.

withShowAllArguments :: ReadTCState m => m a -> m a
withShowAllArguments = withShowAllArguments' True

withShowAllArguments' :: ReadTCState m => Bool -> m a -> m a
withShowAllArguments' yes = withPragmaOptions $ \ opts ->
  opts { optShowImplicit = yes, optShowIrrelevant = yes }

-- | Change 'PragmaOptions' for a computation and restore afterwards.
withPragmaOptions :: ReadTCState m => (PragmaOptions -> PragmaOptions) -> m a -> m a
withPragmaOptions = locallyTCState stPragmaOptions

ignoreInterfaces :: HasOptions m => m Bool
ignoreInterfaces = optIgnoreInterfaces <$> commandLineOptions

ignoreAllInterfaces :: HasOptions m => m Bool
ignoreAllInterfaces = optIgnoreAllInterfaces <$> commandLineOptions

positivityCheckEnabled :: HasOptions m => m Bool
positivityCheckEnabled = not . optDisablePositivity <$> pragmaOptions

{-# SPECIALIZE typeInType :: TCM Bool #-}
typeInType :: HasOptions m => m Bool
typeInType = not . optUniverseCheck <$> pragmaOptions

etaEnabled :: HasOptions m => m Bool
etaEnabled = optEta <$> pragmaOptions

maxInstanceSearchDepth :: HasOptions m => m Int
maxInstanceSearchDepth = optInstanceSearchDepth <$> pragmaOptions

maxInversionDepth :: HasOptions m => m Int
maxInversionDepth = optInversionMaxDepth <$> pragmaOptions

------------------------------------------------------------------------
-- Verbosity

-- Invariant (which we may or may not currently break): Debug
-- printouts use one of the following functions:
--
--   reportS
--   reportSLn
--   reportSDoc

-- | Retrieve the current verbosity level.
{-# SPECIALIZE getVerbosity :: TCM (Trie String Int) #-}
getVerbosity :: HasOptions m => m (Trie String Int)
getVerbosity = optVerbose <$> pragmaOptions

type VerboseKey = String

parseVerboseKey :: VerboseKey -> [String]
parseVerboseKey = wordsBy (`elem` (".:" :: String))

-- | Check whether a certain verbosity level is activated.
--
--   Precondition: The level must be non-negative.
{-# SPECIALIZE hasVerbosity :: VerboseKey -> Int -> TCM Bool #-}
hasVerbosity :: HasOptions m => VerboseKey -> Int -> m Bool
hasVerbosity k n | n < 0     = __IMPOSSIBLE__
                 | otherwise = do
    t <- getVerbosity
    let ks = parseVerboseKey k
        m  = last $ 0 : Trie.lookupPath ks t
    return (n <= m)

-- | Check whether a certain verbosity level is activated (exact match).

{-# SPECIALIZE hasExactVerbosity :: VerboseKey -> Int -> TCM Bool #-}
hasExactVerbosity :: HasOptions m => VerboseKey -> Int -> m Bool
hasExactVerbosity k n =
  (Just n ==) . Trie.lookup (parseVerboseKey k) <$> getVerbosity

-- | Run a computation if a certain verbosity level is activated (exact match).

{-# SPECIALIZE whenExactVerbosity :: VerboseKey -> Int -> TCM () -> TCM () #-}
whenExactVerbosity :: HasOptions m => VerboseKey -> Int -> m () -> m ()
whenExactVerbosity k n = whenM $ hasExactVerbosity k n

__CRASH_WHEN__ :: (HasCallStack, MonadTCM tcm) => VerboseKey -> Int -> tcm ()
__CRASH_WHEN__ k n = whenExactVerbosity k n (throwImpossible err)
  where
    -- Create the "Unreachable" error using *our* caller as the call site.
    err = withFileAndLine' (freezeCallStack callStack) Unreachable

-- | Run a computation if a certain verbosity level is activated.
--
--   Precondition: The level must be non-negative.
{-# SPECIALIZE verboseS :: VerboseKey -> Int -> TCM () -> TCM () #-}
-- {-# SPECIALIZE verboseS :: MonadIO m => VerboseKey -> Int -> TCMT m () -> TCMT m () #-} -- RULE left-hand side too complicated to desugar
{-# SPECIALIZE verboseS :: MonadTCM tcm => VerboseKey -> Int -> tcm () -> tcm () #-}
verboseS :: (MonadTCEnv m, HasOptions m) => VerboseKey -> Int -> m () -> m ()
verboseS k n action = whenM (hasVerbosity k n) $ locallyTC eIsDebugPrinting (const True) action

-- | Verbosity lens.
verbosity :: VerboseKey -> Lens' Int TCState
verbosity k = stPragmaOptions . verbOpt . Trie.valueAt (parseVerboseKey k) . defaultTo 0
  where
    verbOpt :: Lens' (Trie String Int) PragmaOptions
    verbOpt f opts = f (optVerbose opts) <&> \ v -> opts { optVerbose = v }

    defaultTo :: Eq a => a -> Lens' a (Maybe a)
    defaultTo x f m = f (fromMaybe x m) <&> \ v -> if v == x then Nothing else Just v

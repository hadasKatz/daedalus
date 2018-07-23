module MacInstaller
    ( main
    , readCardanoVersionFile
    , withDir
    ) where

---
--- An overview of Mac .pkg internals:    http://www.peachpit.com/articles/article.aspx?p=605381&seqNum=2
---

import           Universum                 hiding (FilePath, toText, (<>))

import           Control.Exception         (handle)
import           Control.Monad             (unless)
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Filesystem.Path           (FilePath, dropExtension, (<.>),
                                            (</>))
import           Filesystem.Path.CurrentOS (encodeString)
import           System.FilePath.Glob      (glob)
import           System.IO                 (BufferMode (NoBuffering),
                                            hSetBuffering)
import           System.IO.Error           (IOError, isDoesNotExistError)
import           Turtle                    hiding (e, prefix, stdout)

import           Config
import           RewriteLibs               (chain)
import           Types
import           Util                      (exportBuildVars)
import           MacOSPackageSigning

data DarwinConfig = DarwinConfig {
    dcAppNameApp :: Text -- ^ Daedalus.app for example
  , dcAppName :: Text -- ^ the Daedalus from Daedalus.app
  , dcPkgName :: Text -- ^ org.daedalus.pkg for example
  } deriving (Show)

gcl :: Options -> GenerateCardanoLauncher
gcl Options{..} = GenerateCardanoLauncher
  { genOS = Macos64
  , genCluster = oCluster
  , genAppName = oAppName
  , genInputDir = "./dhall"
  , genOutputDir = "."
  }

main :: Options -> IO ()
main opts@Options{..} = do
  hSetBuffering stdout NoBuffering

  generateOSClusterConfigs (gcl opts)
  cp "launcher-config.yaml" "../launcher-config.yaml"

  installerConfig <- getInstallerConfig "./dhall" Macos64 oCluster

  let
    darwinConfig = DarwinConfig {
        dcAppNameApp = (installDirectory installerConfig) <> ".app"
      , dcAppName = installDirectory installerConfig
      , dcPkgName = "org." <> (macPackageName installerConfig) <> ".pkg"
      }
  print darwinConfig

  ver <- getBackendVersion oBackend
  exportBuildVars opts ver

  appRoot <- buildElectronApp darwinConfig
  makeComponentRoot opts appRoot darwinConfig
  daedalusVer <- getDaedalusVersion "../package.json"

  let pkg = packageFileName Macos64 oCluster daedalusVer oBackend ver oBuildJob
      opkg = oOutputDir </> pkg

  tempInstaller <- makeInstaller opts darwinConfig appRoot pkg

  signMacOSInstaller tempInstaller opkg
  checkSignature opkg

  run "rm" [tt tempInstaller]
  printf ("Generated "%fp%"\n") opkg

  when (oTestInstaller == TestInstaller) $ do
    echo $ "--test-installer passed, will test the installer for installability"
    procs "sudo" ["installer", "-dumplog", "-verbose", "-target", "/", "-pkg", tt opkg] empty

makePostInstall :: Format a (Text -> a)
makePostInstall = "#!/usr/bin/env bash\n" %
                  "#\n" %
                  "# See /var/log/install.log to debug this\n" %
                  "\n" %
                  "src_pkg=\"$1\"\ndst_root=\"$2\"\ndst_mount=\"$3\"\nsys_root=\"$4\"\n" %
                  "./dockutil --add \"${dst_root}/" % s % "\" --allhomes\n"

makeScriptsDir :: Options -> DarwinConfig -> Managed T.Text
makeScriptsDir Options{..} DarwinConfig{..} = case oBackend of
  Cardano _ -> do
    tempdir <- mktempdir "/tmp" "scripts"
    liftIO $ do
      cp "data/scripts/dockutil" (tempdir </> "dockutil")
      writeTextFile (tempdir </> "postinstall") (format makePostInstall dcAppNameApp)
      run "chmod" ["+x", tt (tempdir </> "postinstall")]
    pure $ tt tempdir
  Mantis    -> pure "[DEVOPS-533]"

-- | Builds the electron app with "npm package" and returns its
-- component root path.
-- NB: If webpack scripts are changed then this function may need to
-- be updated.
buildElectronApp :: DarwinConfig -> IO FilePath
buildElectronApp darwinConfig@DarwinConfig{..} = do
  echo "Creating icons ..."
  procs "iconutil" ["--convert", "icns", "--output", "icons/electron.icns"
                   , "icons/electron.iconset"] mempty

  withDir ".." . sh $ npmPackage darwinConfig

  let
    formatter :: Format r (Text -> Text -> r)
    formatter = "../release/darwin-x64/" % s % "-darwin-x64/" % s
  pure $ fromString $ T.unpack $ format formatter dcAppName dcAppNameApp

npmPackage :: DarwinConfig -> Shell ()
npmPackage DarwinConfig{..} = do
  mktree "release"
  echo "~~~ Installing nodejs dependencies..."
  procs "npm" ["install"] empty
  export "NODE_ENV" "production"
  echo "~~~ Running electron packager script..."
  export "NODE_ENV" "production"
  procs "npm" ["run", "package", "--", "--name", dcAppName ] empty
  size <- inproc "du" ["-sh", "release"] empty
  printf ("Size of Electron app is " % l % "\n") size

getBackendVersion :: Backend -> IO Text
getBackendVersion (Cardano bridge) = readCardanoVersionFile bridge
getBackendVersion Mantis = pure "DEVOPS-533"

makeComponentRoot :: Options -> FilePath -> DarwinConfig -> IO ()
makeComponentRoot Options{..} appRoot darwinConfig@DarwinConfig{..} = do
  let dir     = appRoot </> "Contents/MacOS"

  echo "~~~ Preparing files ..."
  case oBackend of
    Cardano bridge -> do
      -- Executables (from daedalus-bridge)
      forM ["cardano-launcher", "cardano-node", "cardano-x509-certificates"] $ \f ->
        cp (bridge </> "bin" </> f) (dir </> f)

      -- Config files (from daedalus-bridge)
      cp (bridge </> "config/configuration.yaml") (dir </> "configuration.yaml")
      cp (bridge </> "config/log-config-prod.yaml") (dir </> "log-config-prod.yaml")

      -- Genesis (from daedalus-bridge)
      genesisFiles <- glob . encodeString $ bridge </> "config" </> "*genesis*.json"
      when (null genesisFiles) $
        error "Cardano package carries no genesis files."
      procs "cp" (map T.pack genesisFiles ++ [tt dir]) mempty

      -- Config yaml (generated from dhall files)
      cp "launcher-config.yaml" (dir </> "launcher-config.yaml")
      cp "wallet-topology.yaml" (dir </> "wallet-topology.yaml")

      procs "chmod" ["-R", "+w", tt dir] empty

      -- Rewrite libs paths and bundle them
      void $ chain (encodeString dir) $ fmap tt [dir </> "cardano-launcher", dir </> "cardano-node", dir </> "cardano-x509-certificates"]

    Mantis -> pure () -- DEVOPS-533

  -- Prepare launcher
  de <- testdir (dir </> "Frontend")
  unless de $ mv (dir </> (fromString $ T.unpack $ dcAppName)) (dir </> "Frontend")
  run "chmod" ["+x", tt (dir </> "Frontend")]
  void $ writeLauncherFile dir oCluster darwinConfig


makeInstaller :: Options -> DarwinConfig -> FilePath -> FilePath -> IO FilePath
makeInstaller opts@Options{..} darwinConfig@DarwinConfig{..} componentRoot pkg = do
  let tempPkg1 = format fp (oOutputDir </> pkg)
      tempPkg2 = oOutputDir </> (dropExtension pkg <.> "unsigned" <.> "pkg")

  mktree oOutputDir
  with (makeScriptsDir opts darwinConfig) $ \scriptsDir -> do
    let
      pkgargs :: [ T.Text ]
      pkgargs =
           [ "--identifier"
           , dcPkgName
           , "--scripts", scriptsDir
           , "--component"
           , tt componentRoot
           , "--install-location"
           , "/Applications"
           , tempPkg1
           ]
    run "ls" [ "-ltrh", scriptsDir ]
    run "pkgbuild" pkgargs

  run "productbuild" [ "--product", "data/plist"
                     , "--package", tempPkg1
                     , format fp tempPkg2
                     ]

  run "rm" [tempPkg1]
  pure tempPkg2

-- | cardano-sl.daedalus-bridge should have a file containing its version.
readCardanoVersionFile :: FilePath -> IO Text
readCardanoVersionFile bridge = prefix <$> handle handler (readTextFile verFile)
  where
    verFile = bridge </> "version"
    prefix = fromMaybe "UNKNOWN" . safeHead . T.lines
    handler :: IOError -> IO Text
    handler e | isDoesNotExistError e = pure ""
              | otherwise = throwM e

writeLauncherFile :: FilePath -> Cluster -> DarwinConfig -> IO FilePath
writeLauncherFile dir cluster DarwinConfig{..} = do
  writeTextFile path $ T.unlines contents
  run "chmod" ["+x", tt path]
  pure path
  where
    path = dir </> (fromString $ T.unpack dcAppName)
    dataDir = "$HOME/Library/Application Support/" <> (dcAppName)
    contents =
      [ "#!/usr/bin/env bash"
      , "cd \"$(dirname \"$0\")\""
      , "mkdir -p \"" <> dataDir <> "/Secrets-1.0\""
      , "mkdir -p \"" <> dataDir <> "/Logs/pub\""
      , "export NETWORK=" <> clusterNetwork cluster
      , "export REPORT_URL=\"fixme\""
      , "./cardano-launcher"
      ]

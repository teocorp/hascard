{-# LANGUAGE TemplateHaskell #-}
module Main where

import UI
import Control.Exception (displayException, try)
import Control.Monad (void, when)
import Data.Version (showVersion)
import Lens.Micro.Platform
import Paths_hascard (version)
import Parser
import Options.Applicative
import System.Directory (makeAbsolute)
import System.FilePath (takeExtension, takeBaseName, takeDirectory)
import System.Process (runCommand)
import System.Random.MWC (createSystemRandom)
import qualified Data.Map.Strict as Map (empty)
import qualified System.Directory as D
import qualified Stack

data Command = Command
  | Run RunOpts
  | Import ImportOpts

data Opts = Opts
  { _optCommand      :: Maybe Command
  , _optVersion      :: Bool
  }

data RunOpts = RunOpts
  { _optFile         :: Maybe String
  , _optSubset       :: Int
  , _optChunk        :: Chunk
  , _optShuffle      :: Bool
  , _optBlankMode    :: Bool
  }

data ImportOpts = ImportOpts
  { _optInput         :: String 
  , _optOutput        :: String
  , _optImportType    :: ImportType
  , _optImportReverse :: Bool }

makeLenses ''Opts
makeLenses ''RunOpts
makeLenses ''ImportOpts

main :: IO ()
main = do
  useEscapeCode <- getUseEscapeCode
  when useEscapeCode $ void (runCommand "echo -n \\\\e[5 q")
  
  options <- execParser optsWithHelp
  case (options ^. optVersion, options ^. optCommand) of
    (True, _)                -> putStrLn (showVersion version)
    (_, Just (Run rOpts))    -> run rOpts
    (_, Just (Import iOpts)) -> doImport iOpts
    (_, Nothing)             ->
      do g <- createSystemRandom 
         let gs = GlobalState {_mwc=g, _states=Map.empty, _stack=Stack.empty, _parameters= defaultParameters }
         start Nothing gs

opts :: Parser Opts
opts = Opts
  <$> optional (hsubparser
    (  command "run" (info (Run <$> runOpts) ( progDesc "Run hascard with CLI options"))
    <> command "import" (info (Import <$> importOpts) (progDesc "Convert a TAB delimited file to syntax compatible with hascard. So, terms and definitions should be seperated by tabs, and rows by new lines. When converting to 'open' cards, multiple correct answers can be seperated by semicolons (;), backslashes (/) or commas (,)."))))
  <*> switch (long "version" <> short 'v' <> help "Show version number")

runOpts :: Parser RunOpts
runOpts = RunOpts
  <$> optional (argument str (metavar "FILE" <> help "A .txt or .md file containing flashcards"))
  <*> option auto (long "amount" <> short 'a' <> metavar "n" <> help "Use the first n cards in the deck (most useful combined with shuffle)" <> value (-1))
  <*> option auto (long "chunk" <> short 'c' <> metavar "i/n" <> help "Split the deck into n chunks, and review the i'th one. Counting starts at 1." <> value (Chunk 1 1))
  <*> switch (long "shuffle" <> short 's' <> help "Randomize card order")
  <*> switch (long "blank" <> short 'b' <> help "Disable review mode: do not keep track of which questions were correctly and incorrectly answered")

importOpts :: Parser ImportOpts
importOpts = ImportOpts
  <$> argument str (metavar "INPUT" <> help "A TSV file")
  <*> argument str (metavar "DESINATION" <> help "The filename/path to which the output should be saved")
  <*> option auto (long "type" <> short 't' <> metavar "'open' or 'def'" <> help "The type of card to which the input is transformed, default: open" <> value Open)
  <*> switch (long "reverse" <> short 'r' <> help "Reverse direction of question and answer, i.e. right part becomes the question.")

optsWithHelp :: ParserInfo Opts
optsWithHelp = info (opts <**> helper) $
              fullDesc <> progDesc "Run the normal application with `hascard`. To run directly on a file, and with CLI options, see `hascard run --help`. For converting TAB seperated files, see `hascard import --help`."
              <> header "Hascard - a TUI for reviewing notes"

nothingIf :: (a -> Bool) -> a -> Maybe a
nothingIf p a
  | p a = Nothing
  | otherwise = Just a

mkGlobalState :: RunOpts -> GenIO -> GlobalState
mkGlobalState opts gen = 
  let ps = Parameters { _pShuffle = opts^.optShuffle, _pSubset = nothingIf (<0) (opts^.optSubset)
                      , _pChunk = opts^.optChunk, _pReviewMode = not (opts^.optBlankMode), _pOk = False }
  in GlobalState {_mwc=gen, _states=Map.empty, _stack=Stack.empty, _parameters=ps }

cleanFilePath :: FilePath -> IO (Either String FilePath)
cleanFilePath fp = case takeExtension fp of
  ".txt" -> return $ Right fp
  ".md"  -> return $ Right fp
  ""     -> do existence <- mapM D.doesFileExist [fp <> ".txt", fp <> ".md"]
               return $ case existence of
                 [True, True] -> Left "Both a .txt and .md file of this name exist, and it is unclear which to use. Specify the file extension."
                 [True, _   ] -> Right $ fp <> ".txt"     
                 [_   , True] -> Right $ fp <> ".md"
                 _            -> Left $ "No .txt or .md file with the name \""
                                        <> takeBaseName fp
                                        <> "\" in the directory \""
                                        <> takeDirectory fp
                                        <> "\""
              
  _      -> return $ Left "Incorrect file type, provide a .txt file"
  
run :: RunOpts -> IO ()
run opts = run' (opts ^. optFile)
  where
    run' Nothing = createSystemRandom >>= start Nothing . mkGlobalState opts
    run' (Just dirtyFp) = do
      msgOrFp <- cleanFilePath dirtyFp
      case msgOrFp of
        Left msg -> putStrLn msg
        Right fp -> do
          valOrExc <- try (readFile fp) :: IO (Either IOError String)
          case valOrExc of
            Left exc -> putStrLn (displayException exc)
            Right val -> case parseCards val of
              Left parseError -> putStr parseError
              Right result ->
                do gen <- createSystemRandom
                   makeAbsolute fp >>= addRecent
                   start (Just (fp, result)) (mkGlobalState opts gen)

start :: Maybe (FilePath, [Card]) -> GlobalState -> IO ()
start Nothing gs = runBrickFlashcards (gs `goToState` mainMenuState)
start (Just (fp, cards)) gs = runBrickFlashcards =<< (gs `goToState`) <$> cardsWithOptionsState gs fp cards

doImport :: ImportOpts -> IO ()
doImport opts = do
  valOrExc <- try $ readFile (opts ^. optInput) :: IO (Either IOError String)
  case valOrExc of
    Left exc -> putStrLn (displayException exc)
    Right val -> do
      let mCards = parseImportInput (opts ^. optImportType) (opts ^. optImportReverse) val
      case mCards of
        Just cards -> do
          writeFile (opts ^. optOutput) . cardsToString $ cards
          putStrLn "Successfully converted the file."
        Nothing -> putStrLn "Failed the conversion."
         
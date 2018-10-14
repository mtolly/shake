{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables, ConstraintKinds, RecordWildCards, GeneralizedNewtypeDeriving, Rank2Types #-}

module General.Extra(
    getProcessorCount,
    findGcc,
    whenLeft,
    randomElem,
    wrapQuote, showBracket,
    withs,
    maximum', maximumBy',
    fastAt,
    forkFinallyUnmasked,
    isAsyncException,
    usingLineBuffering,
    doesFileExist_,
    usingNumCapabilities,
    removeFile_, createDirectoryRecursive,
    catchIO, tryIO, handleIO,
    Located, Partial, callStackTop, callStackFull, withFrozenCallStack,
    Ver(..), makeVer,
    QTypeRep(..)
    ) where

import Control.Exception.Extra
import Data.Char
import Data.List.Extra
import System.Environment.Extra
import Development.Shake.FilePath
import Control.DeepSeq
import Numeric
import General.Cleanup
import Data.Typeable
import System.IO.Extra
import System.IO.Unsafe
import System.Info.Extra
import System.Random
import System.Directory
import System.Exit
import Foreign.Storable
import Control.Concurrent.Extra
import Data.Maybe
import Data.Functor
import Data.Hashable
import Data.Primitive.Array
import Control.Applicative
import Control.Monad
import Control.Monad.ST
import GHC.Conc(getNumProcessors)
#if __GLASGOW_HASKELL__ >= 800
import GHC.Stack
#endif
import Prelude


---------------------------------------------------------------------
-- Prelude

-- See https://ghc.haskell.org/trac/ghc/ticket/10830 - they broke maximumBy
maximumBy' :: (a -> a -> Ordering) -> [a] -> a
maximumBy' cmp = foldl1' $ \x y -> if cmp x y == GT then x else y

maximum' :: Ord a => [a] -> a
maximum' = maximumBy' compare


---------------------------------------------------------------------
-- Data.List

-- | If a string has any spaces then put quotes around and double up all internal quotes.
--   Roughly the inverse of Windows command line parsing.
wrapQuote :: String -> String
wrapQuote xs | any isSpace xs = "\"" ++ concatMap (\x -> if x == '\"' then "\"\"" else [x]) xs ++ "\""
             | otherwise = xs

-- | If a string has any spaces then put brackets around it.
wrapBracket :: String -> String
wrapBracket xs | any isSpace xs = "(" ++ xs ++ ")"
               | otherwise = xs

-- | Alias for @wrapBracket . show@.
showBracket :: Show a => a -> String
showBracket = wrapBracket . show


-- | Version of '!!' which is fast and returns 'Nothing' if the index is not present.
fastAt :: [a] -> (Int -> Maybe a)
fastAt xs = \i -> if i < 0 || i >= n then Nothing else Just $ indexArray arr i
    where
        n = length xs
        arr = runST $ do
            let n = length xs
            arr <- newArray n undefined
            forM_ (zipFrom 0 xs) $ \(i,x) ->
                writeArray arr i x
            unsafeFreezeArray arr


---------------------------------------------------------------------
-- System.Info

{-# NOINLINE getProcessorCount #-}
getProcessorCount :: IO Int
-- unsafePefromIO so we cache the result and only compute it once
getProcessorCount = let res = unsafePerformIO act in return res
    where
        act =
            if rtsSupportsBoundThreads then
                fromIntegral <$> getNumProcessors
            else do
                env <- lookupEnv "NUMBER_OF_PROCESSORS"
                case env of
                    Just s | [(i,"")] <- reads s -> return i
                    _ -> do
                        src <- readFile' "/proc/cpuinfo" `catchIO` \_ -> return ""
                        return $! max 1 $ length [() | x <- lines src, "processor" `isPrefixOf` x]


-- Can you find a GCC executable? return a Bool, and optionally something to add to $PATH to run it
findGcc :: IO (Bool, Maybe FilePath)
findGcc = do
    v <- findExecutable "gcc"
    case v of
        Nothing | isWindows -> do
            ghc <- findExecutable "ghc"
            case ghc of
                Just ghc -> do
                    let gcc = takeDirectory (takeDirectory ghc) </> "mingw/bin/gcc.exe"
                    b <- doesFileExist_ gcc
                    return $ if b then (True, Just $ takeDirectory gcc) else (False, Nothing)
                _ -> return (False, Nothing)
        _ -> return (isJust v, Nothing)



---------------------------------------------------------------------
-- System.Random

randomElem :: [a] -> IO a
randomElem xs = do
    when (null xs) $ fail "General.Extra.randomElem called with empty list, can't pick a random element"
    i <- randomRIO (0, length xs - 1)
    return $ xs !! i


---------------------------------------------------------------------
-- System.IO

usingLineBuffering :: Cleanup -> IO ()
usingLineBuffering cleanup = do
    out <- hGetBuffering stdout
    err <- hGetBuffering stderr
    when (out /= LineBuffering || err /= LineBuffering) $ do
        register cleanup $ hSetBuffering stdout out >> hSetBuffering stderr err
        hSetBuffering stdout LineBuffering >> hSetBuffering stderr LineBuffering


---------------------------------------------------------------------
-- Control.Monad

withs :: [(a -> r) -> r] -> ([a] -> r) -> r
withs [] act = act []
withs (f:fs) act = f $ \a -> withs fs $ \as -> act $ a:as


---------------------------------------------------------------------
-- Control.Concurrent

-- | Like 'forkFinally', but the inner thread is unmasked even if you started masked.
forkFinallyUnmasked :: IO a -> (Either SomeException a -> IO ()) -> IO ThreadId
forkFinallyUnmasked act cleanup =
    mask_ $ forkIOWithUnmask $ \unmask ->
        try (unmask act) >>= cleanup

usingNumCapabilities :: Cleanup -> Int -> IO ()
usingNumCapabilities cleanup new = when rtsSupportsBoundThreads $ do
    old <- getNumCapabilities
    when (old /= new) $ do
        register cleanup $ setNumCapabilities old
        setNumCapabilities new


---------------------------------------------------------------------
-- Control.Exception

-- | Is the exception asynchronous, not a "coding error" that should be ignored
isAsyncException :: SomeException -> Bool
isAsyncException e
    | Just (_ :: AsyncException) <- fromException e = True
    | Just (_ :: ExitCode) <- fromException e = True
    | otherwise = False

catchIO :: IO a -> (IOException -> IO a) -> IO a
catchIO = Control.Exception.Extra.catch -- GHC 7.4 has catch in the Prelude as well

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

handleIO :: (IOException -> IO a) -> IO a -> IO a
handleIO = flip catchIO


---------------------------------------------------------------------
-- System.Directory

doesFileExist_ :: FilePath -> IO Bool
doesFileExist_ x = doesFileExist x `catchIO` \_ -> return False

-- | Remove a file, but don't worry if it fails
removeFile_ :: FilePath -> IO ()
removeFile_ x = removeFile x `catchIO` \_ -> return ()

-- | Like @createDirectoryIfMissing True@ but faster, as it avoids
--   any work in the common case the directory already exists.
createDirectoryRecursive :: FilePath -> IO ()
createDirectoryRecursive dir = do
    x <- tryIO $ doesDirectoryExist dir
    when (x /= Right True) $ createDirectoryIfMissing True dir


---------------------------------------------------------------------
-- Data.Either

whenLeft :: Applicative m => Either a b -> (a -> m ()) -> m ()
whenLeft x f = either f (const $ pure ()) x


---------------------------------------------------------------------
-- Data.CallStack

type Located = Partial

callStackTop :: Partial => String
callStackTop = withFrozenCallStack $ head $ callStackFull ++ ["unknown location"]

callStackFull :: Partial => [String]

#if __GLASGOW_HASKELL__ >= 800

callStackFull = map f $ getCallStack $ popCallStack callStack
    where
        f (_, SrcLoc{..}) = toStandard srcLocFile ++ ":" ++
            -- match the format of GHC error messages
            if srcLocStartLine == srcLocEndLine then
                show srcLocStartLine ++ ":" ++ show srcLocStartCol ++
                (if srcLocStartCol == srcLocEndCol then "" else "-" ++ show srcLocEndCol) ++ ":"
            else
                show (srcLocStartLine, srcLocStartCol) ++ "-" ++ show (srcLocEndLine, srcLocEndCol) ++ ":"
#else

callStackFull = []

withFrozenCallStack :: a -> a
withFrozenCallStack = id
#endif

---------------------------------------------------------------------
-- Data.Version

-- | A version number that indicates change, not ordering or compatibilty.
--   Always presented as an 'Int' to the user, but a newtype inside the library for safety.
newtype Ver = Ver Int
    deriving (Show,Eq,Storable)

makeVer :: String -> Ver
makeVer = Ver . hash


---------------------------------------------------------------------
-- Data.Typeable

-- | Like TypeRep, but the Show includes enough information to be unique
--   so I can rely on @a == b === show a == show b@.
newtype QTypeRep = QTypeRep {fromQTypeRep :: TypeRep}
    deriving (Eq,Hashable)

instance NFData QTypeRep where
    -- Incorrect, but TypeRep doesn't have an NFData until GHC 7.10
    -- See https://github.com/haskell/deepseq/issues/37
    rnf (QTypeRep x) = x `seq` ()

instance Show QTypeRep where
    show (QTypeRep x) = show x ++ " {" ++ showHex (abs $ hashWithSalt 0 x) "" ++ "}"

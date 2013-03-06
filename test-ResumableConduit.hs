import ResumableConduit

import Data.Char
import Data.Conduit
import Data.Conduit.List (sourceNull, sourceList, consume)
import qualified Data.Conduit.List as CL

import Control.Monad.IO.Class

main :: IO ()
main = test

test :: IO ()
test = do
    -- Conduit doesn't know that the [3,3] is the end of the list
    -- until we terminate it.
    let c = CL.groupBy (==) :: Conduit Int IO [Int]
    (c, [[1,1],[2,2]]) <- sourceList [1,1,2,2,3,3] $$ c =$+ consume
    [[3,3]] <- sourceList [] $$ c =$+- consume

    -- An empty case
    let c = CL.groupBy (==) :: Conduit Int IO [Int]
    (c, []) <- sourceNull $$ c =$+ consume
    [] <- sourceNull $$ c =$+- consume

    -- The conduit does not see EOF between incremental feeds
    let c = CL.groupBy (==) :: Conduit Int IO [Int]
    (c, [[1,1],[2,2]]) <- sourceList [1,1,2,2,3,3] $$ c =$+ consume
    (c, []) <- sourceList [3,3,3] $$ c =$++ consume
    (c, [[3,3,3,3,3],[4]]) <- sourceList [4,5] $$ c =$++ consume
    [[5]] <- sourceList [] $$ c =$+- consume

    -- Sink leftovers are returned to the conduit
    let c = CL.groupBy (==) :: Conduit Int IO [Int]

    -- Warning: since the conduit does not consume the input list,
    -- the sourceList data is discarded.  This means we can't treat
    -- multiple source feeds as concatenation of the sources.
    (c, ()) <- sourceList [1,2,2,3,3,3] $$ c =$+ leftover [4,4,4,4]

    (c, ()) <- sourceList [5] $$ c =$++ do
        Just [4,4,4,4] <- await
        Nothing <- await
        leftover [5]
    [[5],[5], [3]] <- sourceList [3] $$ c =$+- consume
        -- Note: this output is inconsistent for the groupBy conduit.
        -- It's the fault of the consumer for producing a 'leftover'
        -- it wasn't given.

    -- A resumable conduit can be used within a sink as a temporary filter.
    c <- sourceList "The quick brown fox jumps over a lazy dog" $$ do
        (c, ["The", "quick"]) <- conduitWords =$+ CL.take 2
        (c, []) <- c =$++ CL.take 0
        (c, ["brown", "fox"]) <- c =$++ CL.take 2
        "jumps ov" <- CL.take 8
        (c, ["er", "a", "lazy"]) <- c =$++ CL.consume
        return c

    -- That conduit can then be returned from the sink and used in
    -- another sink (without forgetting about what it consumed before).
    sourceList "One two three" $$ do
        (c, ["dogOne", "two"]) <- c =$++ CL.consume
        ["three"] <- c =$+- CL.consume
        return ()

    return ()

conduitWords :: Monad m => Conduit Char m String
conduitWords = leadingSpace
  where
    leadingSpace = do
        m <- await
        case m of
            Nothing -> return ()
            Just c
              | isSpace c -> leadingSpace
              | otherwise -> word [c]

    word cs = do
        m <- await
        case m of
            Nothing -> yield (reverse cs)
            Just c
              | isSpace c -> yield (reverse cs) >> leadingSpace
              | otherwise -> word (c:cs)

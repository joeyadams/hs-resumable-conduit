{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE ScopedTypeVariables #-}
module ResumableConduit (
    ResumableConduit,
    (=$+),
    (=$++),
    (=$+-),
) where

import Control.Monad
import Control.Monad.Trans.Class
import Data.Conduit.Internal

infixr 0 =$+
infixr 0 =$++
infixr 0 =$+-

data ResumableConduit i m o = ResumableConduit (Pipe i i o () m ()) (m ())

-- | Fuse a conduit to a sink, but allow the conduit to be reused after the
-- sink returns.
--
-- When the source runs out, the stream terminator is sent directly to
-- the sink, bypassing the conduit.  Some conduits wait for a stream terminator
-- before producing their remaining output, so be sure to use '=$+-'
-- to \"flush\" this data out.
(=$+) :: Monad m => Conduit i m o -> Sink o m r -> Sink i m (ResumableConduit i m o, r)
(=$+) (ConduitM c) sink = ResumableConduit c (return ()) =$++ sink

-- | Continue using a conduit after usage of '=$+'.
(=$++) :: Monad m
       => ResumableConduit i m o
       -> Sink o m r
       -> Sink i m (ResumableConduit i m o, r)
(=$++) = resume True

-- | Complete processing of a 'ResumableConduit'.  It will be closed when
-- the 'Sink' finishes.
(=$+-) :: Monad m => ResumableConduit i m o -> Sink o m r -> Sink i m r
(=$+-) rconduit sink = do
    (ResumableConduit _ final, res) <- resume False rconduit sink
    lift final
    return res

resume :: Monad m
       => Bool
       -> ResumableConduit a m b
       -> ConduitM b c m r
       -> ConduitM a c m (ResumableConduit a m b, r)
resume bypassEOF (ResumableConduit conduit0 final0) (ConduitM sink0) =
    ConduitM (goSink final0 conduit0 sink0)
  where
    goSink final conduit sink = case sink of
        HaveOutput sink' sfinal so -> HaveOutput (goSink final conduit sink') (sfinal >> final) so
                                      -- 'pipe' replicates the final here.
                                      -- Why?  If upstream produces another
                                      -- finalizer, won't we lose ours?
        NeedInput feedK closeK     -> goConduit feedK closeK final conduit
        Done r                     -> Done (ResumableConduit conduit final, r)
        PipeM m                    -> PipeM (liftM (goSink final conduit) m)
        Leftover sink' o           -> goSink final (HaveOutput conduit final o) sink'

    goConduit sinkFeedK sinkCloseK final conduit = case conduit of
        HaveOutput conduit' final' o ->
            goSink final' conduit' (sinkFeedK o)
        NeedInput feedK closeK ->
            NeedInput (goConduit sinkFeedK sinkCloseK final . feedK)
                      (if bypassEOF then
                          -- Forward EOF to sink, but leave the conduit alone
                          -- so it accepts input from the next source.
                          goSink final conduit . sinkCloseK
                       else
                          -- Send EOF through the conduit like 'pipe' does.
                          goConduit sinkFeedK sinkCloseK final . closeK
                      )
        Done rc -> goSink final (Done rc) (sinkCloseK rc)
        PipeM m -> PipeM (liftM (goConduit sinkFeedK sinkCloseK final) m)
        Leftover conduit' i ->
            Leftover (goConduit sinkFeedK sinkCloseK final conduit') i

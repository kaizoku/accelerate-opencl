{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE BangPatterns, CPP, GADTs, TupleSections, TypeSynonymInstances #-}
-- |
-- Module      : Data.Array.Accelerate.OpenCL.Compile
-- Copyright   : [2008..2011] Manuel M T Chakravarty, Gabriele Keller, Sean Lee, Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Manuel M T Chakravarty <chak@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-partable (GHC extensions)
--

module Data.Array.Accelerate.OpenCL.Compile (

  -- * Types parameterising our annotated computation form
  ExecAcc, ExecOpenAcc(..),
  AccKernel, AccRefcount(..),

  -- * generate and compile kernels to realise a computation
  compileAcc, compileAfun1

) where

#include "accelerate.h"

-- friends
import Data.Array.Accelerate.Type
import Data.Array.Accelerate.Tuple
import Data.Array.Accelerate.AST                        hiding (Val(..))
import Data.Array.Accelerate.Array.Sugar                (Array(..), Segments, Shape, Elt)
import Data.Array.Accelerate.Array.Representation       hiding (Shape)
--import Data.Array.Accelerate.Pretty.Print

import Data.Array.Accelerate.OpenCL.State
import Data.Array.Accelerate.OpenCL.CodeGen
import Data.Array.Accelerate.OpenCL.Array.Data
import Data.Array.Accelerate.OpenCL.Analysis.Hash

-- libraries
import Prelude                                          hiding (exp)
--import Control.Applicative                              hiding (Const)
import Control.Monad.Trans
import Control.Monad
import Control.Concurrent                               (forkIO)
import Control.Concurrent.MVar
import Data.Maybe
import Data.Label
import Data.Label.Monadic   (gets, puts)
--import Language.C
import System.FilePath
import System.Directory
--import System.IO
--import System.Exit                                      (ExitCode(..))
--import System.Posix.Types                               (ProcessID)
--import System.Posix.Process
--import Text.PrettyPrint
--import Foreign.Storable
import qualified Data.HashTable                         as Hash

import qualified Foreign.OpenCL.Bindings                as OpenCL

import Paths_accelerate_opencl                          (getDataDir)


-- A binary object that will be used to execute a kernel
--
type AccKernel a = (String, CIO OpenCL.Program)

noKernel :: AccKernel a
noKernel = INTERNAL_ERROR(error) "ExecAcc" "no kernel module for this node"

-- The number of times an array computation will be used. This is an overzealous
-- estimate, due to the presence of array branching. Only the scanl' and scanr'
-- primitives use two reference counts.
--
data AccRefcount = R1 !Int
                 | R2 !Int !Int

instance Show AccRefcount where
  show (R1 x)   = show x
  show (R2 x y) = show (x,y)

noRefcount :: AccRefcount
noRefcount = INTERNAL_ERROR(error) "ExecAcc" "no reference count for this node"

singleRef :: AccRefcount
singleRef = R1 1


-- A pseudo array environment that holds the number of times each indexed
-- variable has been accessed.
--
data Ref c where
  Empty :: Ref ()
  Push  :: Ref c
        -> Either (IndirectRef c) AccRefcount
        -> Ref (c, AccRefcount)

data IndirectRef c = forall env t.
                     IRef (Idx env t) (AccRefcount -> AccRefcount)


incIdx :: Idx env t -> Ref count -> Ref count
incIdx = modIdx incR1
  where
    incR1 (R1 x) = R1 (x+1)
    incR1 _      = INTERNAL_ERROR(error) "incR1" "inconsistent valuation"

modIdx :: (AccRefcount -> AccRefcount) -> Idx env t -> Ref count -> Ref count
modIdx f (SuccIdx ix) (Push next c) = modIdx f ix next `Push` c
modIdx f ZeroIdx      (Push rest c) =
  case c of
    Left (IRef ix' f') -> modIdx f' ix' rest `Push` c
    Right n            -> rest               `Push` Right (f n)
modIdx _ _            _             = INTERNAL_ERROR(error) "modIdx" "inconsistent valuation"


-- Interleave execution state annotations into an open array computation AST
--
data ExecOpenAcc aenv a where
  ExecAfun :: AccRefcount                       -- reference count attached to an enclosed lambda
           -> PreOpenAfun ExecOpenAcc () t
           -> ExecOpenAcc aenv t

  ExecAcc  :: AccRefcount                       -- number of times the result is used (zealous)
           -> AccKernel a                       -- an executable binary object
           -> [AccBinding aenv]                 -- auxiliary arrays from the environment the kernel needs access to
           -> PreOpenAcc ExecOpenAcc aenv a     -- the actual computation
           -> ExecOpenAcc aenv a

-- An annotated AST suitable for execution in the OpenCL environment
--
type ExecAcc a = ExecOpenAcc () a

-- instance Show (ExecOpenAcc aenv a) where
--   show = render . prettyExecAcc 0 noParens


-- |Initiate code generation, compilation, and data transfer for an array
-- expression. If we are in `streaming' mode, then the arrays are marked so that
-- they will be retained between iterations.
--
-- The returned array computation is annotated so to be suitable for execution
-- in the OpenCL environment. This includes:
--
--   1. The kernel module that can be used to execute the computation, and the
--      list of array variables that were embedded within scalar expressions
--      (TLM: todo)
--
--   2. Array reference counts (TLM: not accurate in the presence of branches)
--
--   3. Wrap the segment descriptor of FoldSeg and similar in 'Scanl (+) 0', to
--      transform the segment lengths into global offset indices.
--
compileAcc :: Acc a -> CIO (ExecAcc a)
compileAcc acc = fst `fmap` prepareAcc False acc Empty


compileAfun1 :: Afun (a -> b) -> CIO (ExecAcc (a -> b))
compileAfun1 (Alam (Abody b)) = do
  (b', Empty `Push` Right c) <- prepareAcc True b (Empty `Push` Right (R1 0))
  return $ ExecAfun c (Alam (Abody b'))

compileAfun1 _ =
  error "Hope (noun): something that happens to facts when the world refuses to agree"


prepareAcc :: Bool -> OpenAcc aenv a -> Ref count -> CIO (ExecOpenAcc aenv a, Ref count)
prepareAcc iss rootAcc rootEnv = do
  puts memoryTable =<< liftIO newAccMemoryTable
  travA rootAcc rootEnv
  where
    -- Traverse an open array expression in depth-first order
    --
    travA :: OpenAcc aenv a -> Ref count -> CIO (ExecOpenAcc aenv a, Ref count)
    travA acc@(OpenAcc pacc) aenv =
      case pacc of

        -- Environment manipulations
        --
        Avar ix -> return (node (Avar ix), incIdx ix aenv)

        -- Let bindings to a single computation
        --
        Alet a b | Alet _ _ <- unAcc a -> do
          (ExecAcc _ _ _ (Alet x' y'), env1) <- travA a aenv
          (b', env2 `Push` Right c)         <- travA b (env1 `Push` Right (R1 0))
          return (node (Alet (node (Alet x' (setref c y'))) b'), env2)

        Alet a b  -> do
          (a', env1)                <- travA a aenv
          (b', env2 `Push` Right c) <- travA b (env1 `Push` Right rc)
          return (node (Alet (setref c a') b'), env2)
          where
            rc | isAcc2 a  = R2 0 0
               | otherwise = R1 0


        Apply (Alam (Abody b)) a -> do
          (a', env1)                <- travA a aenv
          (b', env2 `Push` Right c) <- travA b (env1 `Push` Right (R1 0))
          return (node (Apply (Alam (Abody b')) (setref c a')), env2)
        Apply _                _ -> error "I made you a cookie, but I eated it"

        Acond c t e -> do
          (c', env1, _) <- travE c aenv []
          (t', env2)    <- travA t env1      -- TLM: separate use counts for each branch?
          (e', env3)    <- travA e env2
          return (ExecAcc noRefcount noKernel [] (Acond c' t' e'), env3)

        -- Array injection
        --
        -- If this array is let-bound, we will only see this case once, and need
        -- to update the reference count when retrieved during execution
        --
        Use arr@(Array sh ad) ->
          let n = size sh
              c = if iss then Nothing else Just 1
          in do mallocArray    ad c (max 1 n)
--                pokeArrayAsync ad n Nothing
                pokeArray ad n
                return (ExecAcc singleRef noKernel [] (Use arr), aenv)

        -- Computation nodes
        --
        Reshape sh a -> do
          (sh', env1, _) <- travE sh aenv []
          (a',  env2)    <- travA a  env1
          return (ExecAcc singleRef noKernel [] (Reshape sh' a'), env2)

        Unit e  -> do
          (e', env1, _) <- travE e aenv []
          return (ExecAcc singleRef noKernel [] (Unit e'), env1)

        Generate e f -> do
          (e', env1, _)    <- travE e aenv []
          (f', env2, var1) <- travF f env1 []
          kernel           <- build "generate" acc var1
          return (ExecAcc singleRef kernel var1 (Generate e' f'), env2)

        Replicate slix e a -> do
          (e', env1, _) <- travE e aenv []
          (a', env2)    <- travA a env1
          kernel        <- build "replicate" acc []
          return (ExecAcc singleRef kernel [] (Replicate slix e' a'), env2)

        Slice slix a e -> do
          (a', env1)    <- travA a aenv
          (e', env2, _) <- travE e env1 []
          kernel        <- build "slice" acc []
          return (ExecAcc singleRef kernel [] (Slice slix a' e'), env2)

        Map f a -> do
          (f', env1, var1) <- travF f aenv []
          (a', env2)       <- travA a env1
          kernel           <- build "map" acc var1
          return (ExecAcc singleRef kernel var1 (Map f' a'), env2)

        ZipWith f a b -> do
          (f', env1, var1) <- travF f aenv []
          (a', env2)       <- travA a env1
          (b', env3)       <- travA b env2
          kernel           <- build "zipWith" acc var1
          return (ExecAcc singleRef kernel var1 (ZipWith f' a' b'), env3)

        Fold f e a -> do
          (f', env1, var1) <- travF f aenv []
          (e', env2, var2) <- travE e env1 var1
          (a', env3)       <- travA a env2
          kernel           <- build "fold" acc var2
          return (ExecAcc singleRef kernel var2 (Fold f' e' a'), env3)

        Fold1 f a -> do
          (f', env1, var1) <- travF f aenv []
          (a', env2)       <- travA a env1
          kernel           <- build "fold" acc var1
          return (ExecAcc singleRef kernel var1 (Fold1 f' a'), env2)

        FoldSeg _ _ _ _    -> notSupported "foldSeg"
        Fold1Seg _ _ _     -> notSupported "fold1Seg"
        Scanl _ _ _        -> notSupported "scanl"
        Scanl' _ _ _       -> notSupported "scanl'"
        Scanr _ _ _        -> notSupported "scanr"
        Scanr' _ _ _       -> notSupported "scanr'"
        Scanr1 _ _         -> notSupported "scanr1"
        Stencil _ _ _      -> notSupported "stencil"
        Stencil2 _ _ _ _ _ -> notSupported "stencil2"
        Permute _ _ _ _    -> notSupported "permute"
        Backpermute _ _ _  -> notSupported "backpermute"

        -- Permute f a g b -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (g', env2, var2) <- travF g env1 var1
        --   (a', env3)       <- travA a env2
        --   (b', env4)       <- travA b env3
        --   kernel           <- build "permute" acc var2
        --   return (ExecAcc singleRef kernel var2 (Permute f' a' g' b'), env4)

        -- Backpermute e f a -> do
        --   (e', env1, _)    <- travE e aenv []
        --   (f', env2, var2) <- travF f env1 []
        --   (a', env3)       <- travA a env2
        --   kernel           <- build "backpermute" acc var2
        --   return (ExecAcc singleRef kernel var2 (Backpermute e' f' a'), env3)

        -- FoldSeg f e a s -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (e', env2, var2) <- travE e env1 var1
        --   (a', env3)       <- travA a env2
        --   (s', env4)       <- travA (scan s) env3
        --   kernel           <- build "foldSeg" acc var2
        --   return (ExecAcc singleRef kernel var2 (FoldSeg f' e' a' s'), env4)

        -- Fold1Seg f a s -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (a', env2)       <- travA a env1
        --   (s', env3)       <- travA (scan s) env2
        --   kernel           <- build "foldSeg" acc var1
        --   return (ExecAcc singleRef kernel var1 (Fold1Seg f' a' s'), env3)

        -- Scanl f e a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (e', env2, var2) <- travE e env1 var1
        --   (a', env3)       <- travA a env2
        --   kernel           <- build "inclusive_scan" acc var2
        --   return (ExecAcc singleRef kernel var2 (Scanl f' e' a'), env3)

        -- Scanl' f e a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (e', env2, var2) <- travE e env1 var1
        --   (a', env3)       <- travA a env2
        --   kernel           <- build "inclusive_scan" acc var2
        --   return (ExecAcc (R2 0 0) kernel var2 (Scanl' f' e' a'), env3)

        -- Scanl1 f a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (a', env2)       <- travA a env1
        --   kernel           <- build "inclusive_scan" acc var1
        --   return (ExecAcc singleRef kernel var1 (Scanl1 f' a'), env2)

        -- Scanr f e a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (e', env2, var2) <- travE e env1 var1
        --   (a', env3)       <- travA a env2
        --   kernel           <- build "inclusive_scan" acc var2
        --   return (ExecAcc singleRef kernel var2 (Scanr f' e' a'), env3)

        -- Scanr' f e a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (e', env2, var2) <- travE e env1 var1
        --   (a', env3)       <- travA a env2
        --   kernel           <- build "inclusive_scan" acc var2
        --   return (ExecAcc (R2 0 0) kernel var2 (Scanr' f' e' a'), env3)

        -- Scanr1 f a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (a', env2)       <- travA a env1
        --   kernel           <- build "inclusive_scan" acc var1
        --   return (ExecAcc singleRef kernel var1 (Scanr1 f' a'), env2)

        -- Stencil f b a -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (a', env2)       <- travA a env1
        --   kernel           <- build "stencil" acc var1
        --   return (ExecAcc singleRef kernel var1 (Stencil f' b a'), env2)

        -- Stencil2 f b1 a1 b2 a2 -> do
        --   (f', env1, var1) <- travF f aenv []
        --   (a1', env2)      <- travA a1 env1
        --   (a2', env3)      <- travA a2 env2
        --   kernel           <- build "stencil2" acc var1
        --   return (ExecAcc singleRef kernel var1 (Stencil2 f' b1 a1' b2 a2'), env3)

    notSupported :: String -> a
    notSupported op = INTERNAL_ERROR(error) "prepareAcc" ("Operation " ++ show op ++ " is not yet supported by the OpenCL backend")
    -- notSupported op = error $ "Operation " ++ show op ++ " is not yet supported by the OpenCL backend\n" ++
    --                           "for Accelerate. Please contribute via: http://github.com/HIPERFIT/accelerate-opencl"

    -- Traverse a scalar expression
    --
    travE :: OpenExp env aenv e
          -> Ref count
          -> [AccBinding aenv]
          -> CIO (PreOpenExp ExecOpenAcc env aenv e, Ref count, [AccBinding aenv])
    travE exp aenv vars =
      case exp of
        Var ix          -> return (Var ix, aenv, vars)
        Const c         -> return (Const c, aenv, vars)
        PrimConst c     -> return (PrimConst c, aenv, vars)
        IndexAny        -> INTERNAL_ERROR(error) "prepareAcc" "IndexAny: not implemented yet"
        IndexNil        -> return (IndexNil, aenv, vars)
        IndexCons ix i  -> do
          (ix', env1, var1) <- travE ix aenv vars
          (i',  env2, var2) <- travE i  env1 var1
          return (IndexCons ix' i', env2, var2)

        IndexHead ix    -> do
          (ix', env1, var1) <- travE ix aenv vars
          return (IndexHead ix', env1, var1)

        IndexTail ix    -> do
          (ix', env1, var1) <- travE ix aenv vars
          return (IndexTail ix', env1, var1)

        Tuple t         -> do
          (t', env1, var1) <- travT t aenv vars
          return (Tuple t', env1, var1)

        Prj idx e       -> do
          (e', env1, var1) <- travE e aenv vars
          return (Prj idx e', env1, var1)

        Cond p t e      -> do
          (p', env1, var1) <- travE p aenv vars
          (t', env2, var2) <- travE t env1 var1 -- TLM: reference count contingent on which
          (e', env3, var3) <- travE e env2 var2 --      branch is taken?
          return (Cond p' t' e', env3, var3)

        PrimApp f e     -> do
          (e', env1, var1) <- travE e aenv vars
          return (PrimApp f e', env1, var1)

        Index a e -> do
          (a', env1)       <- travA a aenv
          (e', env2, var2) <- travE e env1 vars
          return (Index a' e', env2, bind a' `cons` var2)

        Shape a         -> do
          (a', env1) <- travA a aenv
          return (Shape a', env1, bind a' `cons` vars)


    travT :: Tuple (OpenExp env aenv) t
          -> Ref count
          -> [AccBinding aenv]
          -> CIO (Tuple (PreOpenExp ExecOpenAcc env aenv) t, Ref count, [AccBinding aenv])
    travT NilTup        aenv vars = return (NilTup, aenv, vars)
    travT (SnocTup t e) aenv vars = do
      (e', env1, var1) <- travE e aenv vars
      (t', env2, var2) <- travT t env1 var1
      return (SnocTup t' e', env2, var2)

    travF :: OpenFun env aenv t
          -> Ref count
          -> [AccBinding aenv]
          -> CIO (PreOpenFun ExecOpenAcc env aenv t, Ref count, [AccBinding aenv])
    travF (Body b) aenv vars = do
      (b', env1, var1) <- travE b aenv vars
      return (Body b', env1, var1)
    travF (Lam  f) aenv vars = do
      (f', env1, var1) <- travF f aenv vars
      return (Lam f', env1, var1)


    -- Auxiliary
    --
    scan :: OpenAcc aenv (Segments Int) -> OpenAcc aenv (Segments Int)
    scan = OpenAcc . Scanl plus (Const ((),0))

    plus :: PreOpenFun OpenAcc () aenv (Int -> Int -> Int)
    plus = Lam (Lam (Body (PrimAdd numType
                          `PrimApp`
                          Tuple (NilTup `SnocTup` Var (SuccIdx ZeroIdx)
                                        `SnocTup` Var ZeroIdx))))

    unAcc :: OpenAcc aenv a -> PreOpenAcc OpenAcc aenv a
    unAcc (OpenAcc pacc) = pacc

    node :: PreOpenAcc ExecOpenAcc aenv a -> ExecOpenAcc aenv a
    node = ExecAcc noRefcount noKernel []

    isAcc2 :: OpenAcc aenv a -> Bool
    isAcc2 (OpenAcc pacc) = case pacc of
        Scanl' _ _ _ -> True
        Scanr' _ _ _ -> True
        _            -> False

    incSucc :: AccRefcount -> AccRefcount
    incSucc (R2 x y) = R2 (x+1) y
    incSucc _        = INTERNAL_ERROR(error) "incSucc" "inconsistent valuation"

    incZero :: AccRefcount -> AccRefcount
    incZero (R2 x y) = R2 x (y+1)
    incZero _        = INTERNAL_ERROR(error) "incZero" "inconsistent valuation"

    eitherIx :: Idx env t -> f -> f -> f
    eitherIx ZeroIdx           _ z = z
    eitherIx (SuccIdx ZeroIdx) s _ = s
    eitherIx _                 _ _ =
      INTERNAL_ERROR(error) "eitherIx" "inconsistent valuation"

    setref :: AccRefcount -> ExecOpenAcc aenv a -> ExecOpenAcc aenv a
    setref count (ExecAfun _ fun)     = ExecAfun count fun
    setref count (ExecAcc  _ k b acc) = ExecAcc  count k b acc

    cons :: AccBinding aenv -> [AccBinding aenv] -> [AccBinding aenv]
    cons x xs | x `notElem` xs = x : xs
              | otherwise      = xs

    bind :: (Shape sh, Elt e) => ExecOpenAcc aenv (Array sh e) -> AccBinding aenv
    bind (ExecAcc _ _ _ (Avar ix)) = ArrayVar ix
    bind _                         =
     INTERNAL_ERROR(error) "bind" "expected array variable"


-- Compilation
-- -----------

-- Initiate compilation and provide a closure to later link the compiled module
-- when it is required.
--
-- TLM: should get name(s) from code generation
--
build :: String -> OpenAcc aenv a -> [AccBinding aenv] -> CIO (AccKernel a)
build name acc fvar =
  let key = accToKey acc
  in do
    mvar   <- liftIO newEmptyMVar
    table  <- gets kernelTable
    cached <- isJust `fmap` liftIO (Hash.lookup table key)
    unless cached $ compile table key acc fvar
    return . (name,) . liftIO $ memo mvar (link table key)

-- A simple memoisation routine
-- TLM: maybe we can be a bit clever than this...
--
memo :: MVar a -> IO a -> IO a
memo mvar fun = do
  full <- not `fmap` isEmptyMVar mvar
  if full
     then readMVar mvar
     else do a <- fun
             putMVar mvar a
             return a


-- Link a compiled binary and update the associated kernel entry in the hash
-- table. This may entail waiting for the external compilation process to
-- complete. If successfully, the temporary files are removed.
--
link :: KernelTable -> AccKey -> IO OpenCL.Program
link table key =
  let intErr = INTERNAL_ERROR(error) "link" "missing kernel entry"
  in do
    (KernelEntry cufile stat) <- fromMaybe intErr `fmap` Hash.lookup table key
    case stat of
      Right mdl -> return mdl
      Left  mvar -> do
        -- wait for compiler to finish and load binary object
        --
        mdl <- takeMVar mvar
        Hash.insert table key (KernelEntry cufile (Right mdl))
        return mdl

-- Generate and compile code for a single open array expression
--
compile :: KernelTable -> AccKey -> OpenAcc aenv a -> [AccBinding aenv] -> CIO ()
compile table key acc fvar = do
  mvar <- liftIO newEmptyMVar
  ctx <- gets cl_context
  devices <- gets cl_devices

  -- Compile in another thread
  _ <- liftIO . forkIO $ do
         let p = (show $ codeGenAcc acc fvar)
--         putStrLn p
         prog <- OpenCL.createProgram ctx p
         OpenCL.buildProgram prog (map fst devices) =<< compileFlags
         putMVar mvar prog

  liftIO $ Hash.insert table key
             (KernelEntry "compile: kernelName field NOT USED CURRENTLY"
                          (Left mvar))

compileFlags :: IO String
compileFlags = do
  ddir <- liftIO getDataDir
  return $  "-I" ++ (ddir </> "clbits")
            ++ " -I/home/dybber/lib/ati-stream-sdk-v2.3-lnx64/include/"
            ++ "-Werror"
            ++ "-cl-std=CL1.1"



-- Pretty printing
-- ---------------

-- -- Write the generated code to file
-- --
-- writeCode :: FilePath -> CUTranslSkel -> IO ()
-- writeCode f code =
--   withFile f WriteMode $ \hdl ->
--   printDoc PageMode hdl (pretty code)


-- -- stolen from $fptools/ghc/compiler/utils/Pretty.lhs
-- --
-- -- This code has a BSD-style license
-- --
-- printDoc :: Mode -> Handle -> Doc -> IO ()
-- printDoc m hdl doc = do
--   fullRender m cols 1.5 put done doc
--   hFlush hdl
--   where
--     put (Chr c)  next = hPutChar hdl c >> next
--     put (Str s)  next = hPutStr  hdl s >> next
--     put (PStr s) next = hPutStr  hdl s >> next

--     done = hPutChar hdl '\n'
--     cols = 100


-- -- Display the annotated AST
-- --
-- prettyExecAcc :: PrettyAcc ExecOpenAcc
-- prettyExecAcc alvl wrap ecc =
--   case ecc of
--     ExecAfun rc pfun      -> braces (usecount rc)
--                               <+> prettyPreAfun prettyExecAcc alvl pfun
--     ExecAcc  rc _ fv pacc ->
--       let base = prettyPreAcc prettyExecAcc alvl wrap pacc
--           ann  = braces (usecount rc <> comma <+> freevars fv)
--       in case pacc of
--            Avar _         -> base
--            Alet  _ _       -> base
--            Apply _ _      -> base
--            Acond _ _ _    -> base
--            _              -> ann <+> base
--   where
--     usecount (R1 x)   = text "rc=" <> int x
--     usecount (R2 x y) = text "rc=" <> text (show (x,y))
--     freevars = (text "fv=" <>) . brackets . hcat . punctuate comma
--                                . map (\(ArrayVar ix) -> char 'a' <> int (idxToInt ix))


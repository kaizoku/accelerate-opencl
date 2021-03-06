{-# LANGUAGE QuasiQuotes #-}
-- |
-- Module      : Data.Array.Accelerate.OpenCL.CodeGen.Skeleton
-- Copyright   : [2011] Martin Dybdal
-- License     : BSD3
--
-- Maintainer  : Martin Dybdal <dybber@dybber.dk>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- Constructors for array computation skeletons
--

module Data.Array.Accelerate.OpenCL.CodeGen.Skeleton
  (
    mkGenerate,
    mkFold, mkFold1,
--, mkFoldSeg, mkFold1Seg,
    mkMap, mkZipWith,
--    mkStencil, mkStencil2,
--    mkScanl, mkScanr, mkScanl', mkScanr', mkScanl1, mkScanr1,
    mkPermute, mkBackpermute, mkReplicate, mkSlice
  )
  where

import qualified Language.C as C
import Language.C.Syntax
import Language.C.Quote.OpenCL

import Data.Loc
import Data.Symbol

--import Data.Array.Accelerate.Type
import Data.Array.Accelerate.OpenCL.CodeGen.Data
import Data.Array.Accelerate.OpenCL.CodeGen.Util
import Data.Array.Accelerate.OpenCL.CodeGen.Tuple
import Data.Array.Accelerate.OpenCL.CodeGen.Monad
import Data.Array.Accelerate.OpenCL.CodeGen.Reduce (mkFold, mkFold1)
--import Data.Array.Accelerate.CUDA.CodeGen.Stencil


-- -- Construction
-- -- ------------

mkGenerate :: ([C.Type],Int) -> C.Exp -> CUTranslSkel
mkGenerate (tyOut, dimOut) apply = runCGM $ do
    d_out <- mkOutputTuple tyOut
    mkDim "DimOut" dimOut
    mkDim "TyInA" dimOut

    mkApply 1 apply

    ps <- getParams
    addDefinitions
      [cunit|
         __kernel void generate (const typename DimOut shOut,
                                $params:ps) {
             const typename Ix n = $id:(size dimOut)(shOut);
             const typename Ix gridSize  = get_global_size(0);

             for (typename Ix ix = get_global_id(0); ix < n; ix += gridSize) {
                 typename TyOut val = apply($id:(fromIndex dimOut)(shOut, ix));
                 set(ix, val, $args:d_out);
             }
         }
      |]

-- Map
-- ---
mkMap :: [C.Type] -> [C.Type] -> C.Exp -> CUTranslSkel
mkMap tyOut tyIn_A apply = runCGM $ do
  d_out <- mkOutputTuple tyOut
  d_inA <- mkInputTuple "A" tyIn_A
  mkApply 1 apply

  ps <- getParams
  addDefinitions
    [cunit|
       __kernel void map (const typename Ix shape, $params:ps) {
         const typename Ix gridSize = get_global_size(0);

         for(typename Ix idx = get_global_id(0); idx < shape; idx += gridSize) {
           typename TyInA val = getA(idx, $args:d_inA);
           typename TyOut new = apply(val);
           set(idx, new, $args:d_out);
         }
       }
    |]

mkZipWith :: ([C.Type], Int)
          -> ([C.Type], Int)
          ->([C.Type], Int) -> C.Exp -> CUTranslSkel
mkZipWith (tyOut,dimOut) (tyInB, dimInB) (tyInA, dimInA) apply =
  runCGM $ do
    d_out <- mkOutputTuple tyOut
    d_inB <- mkInputTuple "B" tyInB
    d_inA <- mkInputTuple "A" tyInA
    mkApply 2 apply

    mkDim "DimOut" dimOut
    mkDim "DimInB" dimInB
    mkDim "DimInA" dimInA

    ps <- getParams
    addDefinitions
      [cunit|
         __kernel void zipWith (const typename DimOut shOut,
                                const typename DimInB shInB,
                                const typename DimInA shInA,
                                $params:ps) {
           const typename Ix shapeSize = $id:(size dimOut)(shOut);
           const typename Ix gridSize  = get_global_size(0);

           for (typename Ix ix = get_global_id(0); ix < shapeSize; ix += gridSize) {
             typename Ix iA = $id:(toIndex dimInB)(shInB, $id:(fromIndex dimInB)(shOut, ix));
             typename Ix iB = $id:(toIndex dimInA)(shInA, $id:(fromIndex dimInA)(shOut, ix));

             typename TyOut val = apply(getB(iB, $args:d_inB), getA(iA, $args:d_inA)) ;

             set(ix, val, $args:d_out) ;
           }
         }
      |]


-- -- Stencil
-- -- -------

-- mkStencil :: ([CType], Int)
--           -> [CExtDecl] -> [CType] -> [[Int]] -> Boundary [CExpr]
--           -> [CExpr]
--           -> CUTranslSkel
-- mkStencil (tyOut, dim) stencil0 tyIn0 ixs0 boundary0 apply = CUTranslSkel code [] skel
--   where
--     skel = "stencil.inl"
--     code = CTranslUnit
--             ( stencil0                   ++
--               mkTupleType Nothing  tyOut ++
--             [ mkDim "DimOut" dim
--             , mkDim "DimIn0" dim
--             , head $ mkTupleType (Just 0) tyIn0 -- just the scalar type
--             , mkStencilType 0 (length ixs0) tyIn0 ] ++
--               mkStencilGet 0 boundary0 tyIn0 ++
--             [ mkStencilGather 0 dim tyIn0 ixs0
--             , mkStencilApply 1 apply ] )
--             (mkNodeInfo (initPos skel) (Name 0))


-- mkStencil2 :: ([CType], Int)
--            -> [CExtDecl] -> [CType] -> [[Int]] -> Boundary [CExpr]
--            -> [CExtDecl] -> [CType] -> [[Int]] -> Boundary [CExpr]
--            -> [CExpr]
--            -> CUTranslSkel
-- mkStencil2 (tyOut, dim) stencil1 tyIn1 ixs1 boundary1
--                         stencil0 tyIn0 ixs0 boundary0 apply =
--   CUTranslSkel code [] skel
--   where
--     skel = "stencil2.inl"
--     code = CTranslUnit
--             ( stencil0                   ++
--               stencil1                   ++
--               mkTupleType Nothing  tyOut ++
--             [ mkDim "DimOut" dim
--             , mkDim "DimIn1" dim
--             , mkDim "DimIn0" dim
--             , head $ mkTupleType (Just 0) tyIn0 -- just the scalar type
--             , head $ mkTupleType (Just 1) tyIn1
--             , mkStencilType 1 (length ixs1) tyIn1
--             , mkStencilType 0 (length ixs0) tyIn0 ] ++
--               mkStencilGet 1 boundary1 tyIn1 ++
--               mkStencilGet 0 boundary0 tyIn0 ++
--             [ mkStencilGather 1 dim tyIn1 ixs1
--             , mkStencilGather 0 dim tyIn0 ixs0
--             , mkStencilApply 2 apply ] )
--             (mkNodeInfo (initPos skel) (Name 0))


-- -- Scan
-- -- ----

-- -- TODO: use a fast scan for primitive types
-- --
-- mkExclusiveScan :: Bool -> Bool -> [CType] -> [CExpr] -> [CExpr] -> CUTranslSkel
-- mkExclusiveScan isReverse isHaskellStyle ty identity apply = CUTranslSkel code defs skel
--   where
--     skel = "scan.inl"
--     defs = [(internalIdent "REVERSE",       Just (fromBool isReverse))
--            ,(internalIdent "HASKELL_STYLE", Just (fromBool isHaskellStyle))]
--     code = CTranslUnit
--             ( mkTupleTypeAsc 2 ty ++
--             [ mkIdentity identity
--             , mkApply 2 apply ])
--             (mkNodeInfo (initPos (takeFileName skel)) (Name 0))

-- mkInclusiveScan :: Bool -> [CType] -> [CExpr] -> CUTranslSkel
-- mkInclusiveScan isReverse ty apply = CUTranslSkel code [rev] skel
--   where
--     skel = "scan1.inl"
--     rev  = (internalIdent "REVERSE", Just (fromBool isReverse))
--     code = CTranslUnit
--             ( mkTupleTypeAsc 2 ty ++
--             [ mkApply 2 apply ])
--             (mkNodeInfo (initPos (takeFileName skel)) (Name 0))

-- mkScanl, mkScanr :: [CType] -> [CExpr] -> [CExpr] -> CUTranslSkel
-- mkScanl = mkExclusiveScan False True
-- mkScanr = mkExclusiveScan True  True

-- mkScanl', mkScanr' :: [CType] -> [CExpr] -> [CExpr] -> CUTranslSkel
-- mkScanl' = mkExclusiveScan False False
-- mkScanr' = mkExclusiveScan True  False

-- mkScanl1, mkScanr1 :: [CType] -> [CExpr] -> CUTranslSkel
-- mkScanl1 = mkInclusiveScan False
-- mkScanr1 = mkInclusiveScan True


-- -- Permutation
-- -- -----------

mkPermute :: [C.Type] -> Int -> Int -> C.Exp -> C.Exp -> CUTranslSkel
mkPermute ty dimOut dimInA combinefn indexfn = runCGM $ do
    (d_out, d_inA : _) <- mkTupleTypeAsc 2 ty
    mkDim "DimOut" dimOut
    mkDim "DimInA" dimInA

    mkApply 2 combinefn
    mkProject Forward indexfn

    ps <- getParams
    addDefinitions
      [cunit|
         __kernel void permute (const typename DimOut shOut,
                                const typename DimInA shInA,
                                $params:ps) {
             const typename Ix shapeSize = $id:(size dimInA)(shInA);
             const typename Ix gridSize  = get_global_size(0);

             for (typename Ix ix = get_global_id(0); ix < shapeSize; ix += gridSize) {
                 typename DimInA src = $id:(fromIndex dimInA)(shIn0, ix);
                 typename DimOut dst = project(src);

                 if (!ignore(dst)) {
                     typename Ix j = $id:(toIndex dimOut)(shOut, dst);

                     typename TyOut val = apply(getA(j, $args:d_out),
                                                getA(ix, $args:d_inA)) ;
                     set(j, val, $args:d_out) ;
                 }
             }
         }
      |]


mkBackpermute :: [C.Type] -> Int -> Int -> C.Exp -> CUTranslSkel
mkBackpermute ty dimOut dimInA indexFn = runCGM $ do
    (d_out, d_inA : _) <- mkTupleTypeAsc 1 ty
    mkDim "DimOut" dimOut
    mkDim "DimInA" dimInA

    mkProject Backward indexFn

    ps <- getParams
    addDefinitions
      [cunit|
         __kernel void backpermute (const typename DimOut shOut,
                                    const typename DimInA shInA,
                                    $params:ps) {
             const typename Ix shapeSize = $id:(size dimInA)(shInA);
             const typename Ix gridSize  = get_global_size(0);

             for (typename Ix ix = get_global_id(0); ix < shapeSize; ix += gridSize) {
                 typename DimOut dst = $id:(fromIndex dimOut)(shOut, ix);
                 typename DimInA src = project(dst);

                 typename Ix j = $id:(toIndex dimInA)(shInA, dst);
                 set(ix, getA(j, $args:d_inA), $args:d_out) ;
             }
         }
      |]


-- Multidimensional Index and Replicate
-- ------------------------------------

mkSlice :: [C.Type] -> Int -> Int -> Int -> C.Exp -> CUTranslSkel
mkSlice ty dimSl dimCo dimInA slix = runCGM $ do
    (d_out, d_inA : _) <- mkTupleTypeAsc 1 ty
    mkDim "Slice" dimSl
    mkDim "SliceDim" dimCo
    mkDim "SliceDim" dimInA

    mkSliceIndex slix

    ps <- getParams
    addDefinitions
      [cunit|
         __kernel void slice (const typename Slice slice,
                              const typename CoSlice slix,
                              const typename SliceDim sliceDim,
                              $params:ps) {
           const typename Ix shapeSize = $id:(size dimSl)(slice);
           const typename Ix gridSize  = get_global_size(0);

           for (typename Ix ix = get_global_id(0); ix < shapeSize; ix += gridSize) {
             typename Slice dst = $id:(fromIndex dimSl)(slice, ix);
             typename SliceDim src = sliceIndex(dst);

             typename Ix j = $id:(toIndex dimInA)(sliceDim, src);
             set(ix, getA(j, $args:d_inA), $args:d_out) ;
           }
         }
      |]

mkReplicate :: [C.Type] -> Int -> Int -> C.Exp -> CUTranslSkel
mkReplicate ty dimSl dimOut slix = runCGM $ do
    (d_out, d_inA : _) <- mkTupleTypeAsc 1 ty
    mkDim "Slice" dimSl
    mkDim "SliceDim" dimOut

    mkSliceReplicate slix

    ps <- getParams
    addDefinitions
      [cunit|
         __kernel void replicate (const typename Slice slice,
                                  const typename SliceDim sliceDim,
                                  $params:ps) {
             const typename Ix shapeSize = $id:(size dimOut)(sliceDim);
             const typename Ix gridSize  = get_global_size(0);

             for (typename Ix ix = get_global_id(0); ix < shapeSize; ix += gridSize) {
                 typename SliceDim dst = $id:(fromIndex dimOut)(sliceDim, ix);
                 typename Slice src = sliceIndex(dst);

                 typename Ix j = $id:(toIndex dimSl)(slice, src);
                 set(ix, getA(j, $args:d_inA), $args:d_out) ;
             }
         }
      |]

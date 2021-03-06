\begin{code}
module TcMonad(
        Tc,     -- The monad type constructor
        runTc, ErrMsg, lift, check,

        -- Environment manipulation
        extendVarEnv, lookupVar,
        getEnvTypes, getFreeTyVars, getMetaTyVars,

        -- Types and unification
        newTyVarTy,
        instantiate, skolemise, zonkType, quantify,
        unify, unifyFun,

        -- Ref cells
        newTcRef, readTcRef, writeTcRef

    ) where

import BasicTypes
import qualified Data.Map as Map
import Text.PrettyPrint.HughesPJ
import Data.IORef
import List( nub, (\\) )

------------------------------------------
--      The monad itself                --
------------------------------------------

data TcEnv
  = TcEnv { uniqs   :: IORef Uniq,         -- Unique supply
            var_env :: Map.Map Name Sigma  -- Type environment for term variables
    }

newtype Tc a = Tc (TcEnv -> IO (Either ErrMsg a))
unTc :: Tc a ->   (TcEnv -> IO (Either ErrMsg a))
unTc (Tc a)  = a

type ErrMsg = Doc

instance Monad Tc where
   return x = Tc (\_env -> return (Right x))
   fail err = Tc (\_env -> return (Left (text err)))
   m >>= k  = Tc (\env -> do { r1 <- unTc m env
                              ; case r1 of
                                  Left err -> return (Left err)
                                  Right v  -> unTc (k v) env })

failTc :: Doc -> Tc a   -- Fail unconditionally
failTc d = fail (docToString d)

check :: Bool -> Doc -> Tc ()
check True  _ = return ()
check False d = failTc d

runTc :: [(Name,Sigma)] -> Tc a -> IO (Either ErrMsg a)
-- Run type-check, given an initial environment
runTc binds (Tc tc)
  = do { ref <- newIORef 0
       ; let { env = TcEnv { uniqs = ref,
                             var_env = Map.fromList binds } }
       ; tc env }
  where

lift :: IO a -> Tc a
-- Lift a state transformer action into the typechecker monad
-- ignores the environment and always succeeds
lift st = Tc (\_env -> do { r <- st; return (Right r) })

newTcRef :: a -> Tc (IORef a)
newTcRef v = lift (newIORef v)

readTcRef :: IORef a -> Tc a
readTcRef r = lift (readIORef r)

writeTcRef :: IORef a -> a -> Tc ()
writeTcRef r v = lift (writeIORef r v)


--------------------------------------------------
--      Dealing with the type environment       --
--------------------------------------------------

extendVarEnv :: Name -> Sigma -> Tc a -> Tc a
extendVarEnv var ty (Tc m)
  = Tc (\env -> m (extend env))
  where
    extend env = env { var_env = Map.insert var ty (var_env env) }

getEnv :: Tc (Map.Map Name Sigma)
getEnv = Tc (\ env -> return (Right (var_env env)))

lookupVar :: Name -> Tc Sigma    -- May fail
lookupVar n = do { env <- getEnv
                 ; case Map.lookup n env of
                     Just ty -> return ty
                     Nothing -> failTc (text "Not in scope:" <+> quotes (pprName n)) }


--------------------------------------------------
--      Creating, reading, writing MetaTvs      --
--------------------------------------------------

newTyVarTy :: Tc Tau
newTyVarTy = do { tv <- newMetaTyVar
                ; return (MetaTv tv) }

newMetaTyVar :: Tc MetaTv
newMetaTyVar = do { uniq <- newUnique
                  ; tref <- newTcRef Nothing
                  ; return (Meta uniq tref) }

newSkolemTyVar :: TyVar -> Tc TyVar
newSkolemTyVar tv = do { uniq <- newUnique
                       ; return (SkolemTv (tyVarName tv) uniq) }


readTv  :: MetaTv -> Tc (Maybe Tau)
readTv  (Meta _ ref) = readTcRef ref

writeTv :: MetaTv -> Tau -> Tc ()
writeTv (Meta _ ref) ty = writeTcRef ref (Just ty)

newUnique :: Tc Uniq
newUnique = Tc (\ (TcEnv {uniqs = ref}) ->
            do { uniq <- readIORef ref ;
               ; writeIORef ref (uniq + 1)
               ; return (Right uniq) })


------------------------------------------
--      Instantiation                   --
------------------------------------------
sig :: Rho a -> Sigma
sig r = ForAll [] r

instantiate :: Sigma -> Tc ExRho
-- Instantiate the topmost for-alls of the argument type
-- with flexible type variables
instantiate (ForAll [] ty) = return $ Ex ty
instantiate (ForAll tvs ty)
  = do { tvs' <- mapM (\_ -> newMetaTyVar) tvs
       ; return $ Ex (substTy tvs (map MetaTv tvs') ty) }

skolemise :: Sigma -> Tc ([TyVar], ExRho)
-- Performs deep skolemisation, returning the
-- skolem constants and the skolemised type
skolemise (ForAll [] (Fun arg_ty res_ty@(ForAll _ _)))  -- Rule PRFUN
  = do { (sks, Ex res_ty') <- skolemise res_ty
       ; return (sks, Ex $ Fun arg_ty (sig res_ty')) }
skolemise (ForAll [] ty)                                -- Rule PRMONO
  = return ([], Ex ty)
skolemise (ForAll tvs ty)                                -- Rule PRPOLY
  = do { sks1 <- mapM newSkolemTyVar tvs
       ; (sks2, ty') <- skolemise (substTy tvs (map TyVar sks1) (sig ty))
       ; return (sks1 ++ sks2, ty') }

------------------------------------------
--      Quantification                  --
------------------------------------------

quantify :: [MetaTv] -> (Rho a) -> Tc Sigma
-- Quantify over the specified type variables (all flexible)
quantify tvs ty
  = do { mapM_ bind (tvs `zip` new_bndrs)   -- 'bind' is just a cunning way
       ; ty' <- zonkType ty                 -- of doing the substitution
       ; return (ForAll new_bndrs ty') }
  where
    used_bndrs = tyVarBndrs ty  -- Avoid quantified type variables in use
    new_bndrs  = take (length tvs) (allBinders \\ used_bndrs)
    bind (tv, name) = writeTv tv (TyVar name)

allBinders :: [TyVar]    -- a,b,..z, a1, b1,... z1, a2, b2,...
allBinders = [ BoundTv [x]          | x <- ['a'..'z'] ] ++
             [ BoundTv (x : show i) | i <- [1 :: Integer ..], x <- ['a'..'z']]

------------------------------------------
--      Getting the free tyvars         --
------------------------------------------

getEnvTypes :: Tc [Type a]
  -- Get the types mentioned in the environment
getEnvTypes = do { env <- getEnv;
                 ; return (Map.elems env) }

getMetaTyVars :: [Type a] -> Tc [MetaTv]
-- This function takes account of zonking, and returns a set
-- (no duplicates) of unbound meta-type variables
getMetaTyVars tys = do { tys' <- mapM zonkType tys
                       ; return (metaTvs tys') }

getFreeTyVars :: [Type a] -> Tc [TyVar]
-- This function takes account of zonking, and returns a set
-- (no duplicates) of free type variables
getFreeTyVars tys = do { tys' <- mapM zonkType tys
                       ; return (freeTyVars tys') }

------------------------------------------
--      Zonking                         --
-- Eliminate any substitutions in the type
------------------------------------------

zonkType :: Type a -> Tc (Type a)
zonkType (ForAll ns ty) = do { ty' <- zonkType ty
                             ; return (ForAll ns ty') }
zonkType (Fun arg res)  = do { arg' <- zonkType arg
                             ; res' <- zonkType res
                             ; return (Fun arg' res') }
zonkType (TyCon tc)     = return (TyCon tc)
zonkType (TyVar n)      = return (TyVar n)
zonkType (MetaTv tv)    -- A mutable type variable
  = do { mb_ty <- readTv tv
       ; case mb_ty of
           Nothing -> return (MetaTv tv)
           Just ty -> do { ty' <- zonkType ty
                         ; writeTv tv ty'       -- "Short out" multiple hops
                         ; return ty' } }


------------------------------------------
--      Unification                     --
------------------------------------------

unify :: Tau -> Tau -> Tc ()

unify ty1 ty2
  | badType ty1 || badType ty2  -- Compiler error
  = failTc (text "Panic! Unexpected types in unification:" <+>
            vcat [ppr ty1, ppr ty2])

unify (TyVar tv1)  (TyVar tv2)  | tv1 == tv2 = return ()
unify (MetaTv tv1) (MetaTv tv2) | tv1 == tv2 = return ()
unify (MetaTv tv) ty = unifyVar tv ty
unify ty (MetaTv tv) = unifyVar tv ty

unify (Fun arg1 res1)
      (Fun arg2 res2)
  = do { (Just arg1, Just arg2, Just res1, Just res2) <- return confirm
       ; unify arg1 arg2; unify res1 res2 }
        where confirm = (confirmTau arg1, confirmTau arg2, confirmTau res1, confirmTau res2)

unify (TyCon tc1) (TyCon tc2)
  | tc1 == tc2
  = return ()

unify ty1 ty2 = failTc (text "Cannot unify types:" <+> vcat [ppr ty1, ppr ty2])



-----------------------------------------
confirmTau :: forall a . Type a -> Maybe Tau
confirmTau (Fun a r) = do { a' <- confirmTau a
                          ; r' <- confirmTau r
                          ; return (Fun a' r') }
confirmTau t@(TyCon _) = Just t
confirmTau t@(TyVar _) = Just t
confirmTau t@(MetaTv _) = Just t

-----------------------------------------
unifyVar :: MetaTv -> Tau -> Tc ()
-- Invariant: tv1 is a flexible type variable
unifyVar tv1 ty2        -- Check whether tv1 is bound
  = do { mb_ty1 <- readTv tv1
       ; case mb_ty1 of
           Just ty1 -> unify ty1 ty2
           Nothing  -> unifyUnboundVar tv1 ty2 }

unifyUnboundVar :: MetaTv -> Tau -> Tc ()
-- Invariant: the flexible type variable tv1 is not bound
unifyUnboundVar tv1 ty2@(MetaTv tv2)
  = do { -- We know that tv1 /= tv2 (else the
         -- top case in unify would catch it)
         mb_ty2 <- readTv tv2
       ; case mb_ty2 of
           Just ty2' -> unify (MetaTv tv1) ty2'
           Nothing  -> writeTv tv1 ty2 }

unifyUnboundVar tv1 ty2
  = do { tvs2 <- getMetaTyVars [ty2]
       ; if tv1 `elem` tvs2 then
            occursCheckErr tv1 ty2
         else
            writeTv tv1 ty2 }

-----------------------------------------
unifyFun :: Rho a -> Tc (Sigma, Sigma)
-- unifies 'fun' with '(arg -> res)'
unifyFun (Fun arg@(ForAll _ _) res) = return (arg, res)
unifyFun tau'          = do { Just tau <- return (confirmTau tau')
                            ; arg_ty <- newTyVarTy
                            ; res_ty <- newTyVarTy
                            ; unify tau (Fun arg_ty res_ty)
                            ; return (sig arg_ty, sig res_ty) }

-----------------------------------------
occursCheckErr :: MetaTv -> Tau -> Tc ()
-- Raise an occurs-check error
occursCheckErr tv ty
  = failTc (text "Occurs check for" <+> quotes (ppr tv) <+>
            text "in:" <+> ppr ty)

badType :: Tau -> Bool
-- Tells which types should never be encountered during unification
badType (TyVar (BoundTv _)) = True
badType _                   = False
\end{code}

import Criterion.Main
import Numeric.AD
import System.Random.MWC (createSystemRandom, GenIO)
import Control.Monad.Par.Class (NFData)
import Data.Bifunctor (second)

import Numeric.LogDomain
import Statistics.Distribution.Polymorphic
import Control.Monad.Bayes.Simple
import Control.Monad.Bayes.Sampler
import Control.Monad.Bayes.Weighted
import Control.Monad.Bayes.Inference hiding (mhStep)
import Control.Monad.Bayes.Population
import Control.Monad.Bayes.Sequential
import Control.Monad.Bayes.Traced
import Control.Monad.Bayes.Inference.MCMC (randomWalkKernel)
import Control.Monad.Bayes.Constraint

import NonlinearSSM
import qualified HMM
import qualified LogReg
import qualified LDA

pdfBenchmarkable :: (Density d) => d -> Domain d -> Benchmarkable
pdfBenchmarkable d = whnf (toLog . pdf d)

pdfBenchmark :: (Density d) => d -> Domain d -> Benchmark
pdfBenchmark d x = bench "density" $ pdfBenchmarkable d x

benchN :: String -> [Int] -> (Int -> Benchmark) -> Benchmark
benchN name ns bmark = bgroup name $ map (\n -> bgroup (show n) [bmark n]) ns

defNs :: [Int]
defNs = [100]

defDiscrete :: Int -> Discrete Double
defDiscrete n = discreteDist $ replicate n 1

pdfBenchmarks :: Benchmark
pdfBenchmarks = bgroup "pdf" [
  bgroup "normal" [ pdfBenchmark (normalDist 1 5) (4 :: Double),
                    bench "grad" $ whnf (head . grad (toLog . pdf (normalDist 1 5) . head )) [4 :: Double]
                  ],
  bgroup "gamma"  [ pdfBenchmark (gammaDist 2 3) (5 :: Double),
                    bench "grad" $ whnf (head . grad (toLog . pdf (gammaDist 2 3) . head )) [5 :: Double]
                  ],
  bgroup "beta"   [ pdfBenchmark (betaDist 2 4) (0.5 :: Double),
                    bench "grad" $ whnf (head . grad (toLog . pdf (normalDist 2 4) . head )) [0.5 :: Double]
                  ],
  bgroup "uniform" [ pdfBenchmark (uniformDist 7 10) (8 :: Double),
                    bench "grad" $ whnf (head . grad (toLog . pdf (normalDist 7 10) . head )) [8 :: Double]
                  ],
  benchN "discrete" defNs (\n -> pdfBenchmark (defDiscrete n) 0)
  ]

samplingBenchmarks :: GenIO -> Benchmark
samplingBenchmarks g = bgroup "sample" [
  bench "normal"  $ whnfIO $ sampleIOwith (normal 1 5)   g,
  bench "gamma"   $ whnfIO $ sampleIOwith (gamma 2 3)    g,
  bench "beta"    $ whnfIO $ sampleIOwith (beta 2 4)     g,
  bench "uniform" $ whnfIO $ sampleIOwith (uniform 7 10) g,
  benchN "discrete" defNs (\n -> bench "sample" $ whnfIO $ sampleIOwith (sample $ defDiscrete n) g)
  ]


benchmarkableIS :: NFData a => GenIO -> Weighted SamplerIO a -> Benchmarkable
benchmarkableIS g m = nfIO $ fmap (second toLog) $ sampleIOwith (runWeighted m) g

benchIS :: NFData a => GenIO -> Weighted SamplerIO a -> Benchmark
benchIS g m = bench "IS" $ benchmarkableIS g m

benchSMC :: NFData a => Int -> [Int] -> GenIO -> Sequential (Population SamplerIO) a -> Benchmark
benchSMC k ns g m =
  benchN "SMC" ns $ \n -> bench "" $ nfIO $ fmap (map fst) $ sampleIOwith (runPopulation $ smcMultinomial k n m) g

benchMH :: NFData a => [Int] -> GenIO -> Traced (Weighted SamplerIO) a -> Benchmark
benchMH ns g m =
  benchN "MH" ns $ \n -> bench "" $ nfIO $ sampleIOwith (prior $ marginal $ composeN n (mhStep k) m) g where
    k = randomWalkKernel 1

    composeN :: Int -> (a -> a) -> a -> a
    composeN 0 _ x = x
    composeN n f x = composeN (n-1) f (f x)

benchSMCRM :: NFData a => Int -> [Int] -> [Int] -> GenIO -> Sequential (Traced (Population SamplerIO)) a -> Benchmark
benchSMCRM k ns ts g m =
  benchN "SMCRM" ns $ \n -> benchN "Trans" ts $ \t -> bench "" $ nfIO $ sampleIOwith (fmap (map fst) $ runPopulation $ smcRM k n t kernel m) g where
    kernel = randomWalkKernel 1

type Model a = (Sequential (Population SamplerIO) a, Traced (Weighted SamplerIO) a, Sequential (Traced (Population SamplerIO)) a)

benchModel :: NFData a => String -> Int -> GenIO -> Model a -> Benchmark
benchModel name k g (mSMC, mMH, mSMCRM) = bgroup name [benchSMC k defNs g mSMC, benchMH defNs g mMH, benchSMCRM k defNs [1] g mSMCRM]

-- benchSSM :: [Int] -> GenIO -> ((forall n. (MonadBayes n, CustomReal n ~ Double) => n (Vector Double)) -> Benchmark)
--          -> Benchmark
-- benchSSM ns g benchF =
--   benchN "SSM" ns $ \n -> env (sampleIOwith (NonlinearSSM.synthesizeData n) g) (benchF . NonlinearSSM.posterior)

-- ssmSMCRMbenchmarks :: [Int] -> GenIO -> [Int] -> [Int] -> Benchmark
-- ssmSMCRMbenchmarks ls g ns ts = benchN "SSM" ls f where
--   f l = env (sampleIOwith (NonlinearSSM.synthesizeData l) g) (benchSMCRM l ns ts g . NonlinearSSM.posterior)
--
-- ssmMHbenchmarks :: [Int] -> GenIO -> [Int] -> Benchmark
-- ssmMHbenchmarks ls g ns = benchN "SSM" ls f where
--   f l = env (sampleIOwith (NonlinearSSM.synthesizeData l) g) (benchMH ns g . NonlinearSSM.posterior)
--
-- ssmSMCbenchmarks :: [Int] -> GenIO -> [Int] -> Benchmark
-- ssmSMCbenchmarks ls g ns = benchN "SSM" ls f where
--   f l = env (sampleIOwith (NonlinearSSM.synthesizeData l) g) (benchSMC l ns g . NonlinearSSM.posterior)
--
-- ssmISbenchmarks :: GenIO -> [Int] -> Benchmark
-- ssmISbenchmarks g ls = benchN "SSM" ls f where
--   f l = env (sampleIOwith (NonlinearSSM.synthesizeData l) g) (benchIS g . NonlinearSSM.posterior)

main :: IO ()
main = do

  g <- createSystemRandom

  let lr = (LogReg.logisticRegression, unconstrain LogReg.logisticRegression, unconstrain LogReg.logisticRegression)
  let hmm = (HMM.hmm, HMM.hmm, HMM.hmm)
  let lda = (LDA.lda, unconstrain LDA.lda, unconstrain LDA.lda)

  let benchmarks = [
        benchModel "LogReg" (length LogReg.xs) g lr,
        benchModel "HMM" (length HMM.values) g hmm,
        benchModel "LDA" (length (concat LDA.docs)) g lda

        --pdfBenchmarks,
        --samplingBenchmarks g,
        -- ssmISbenchmarks g defNs,
        -- ssmSMCbenchmarks defNs g defNs,
        -- ssmMHbenchmarks defNs g defNs,
        -- ssmSMCRMbenchmarks defNs g defNs defNs
        ]

  defaultMain benchmarks

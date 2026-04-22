// export_test.go exposes internal package variables for use by the external
// test package (package nri_test). This file is compiled only during test
// runs and is invisible to non-test callers.
//
// These functions mutate package-level variables and rely on Ginkgo running
// specs serially within a single OS process (the default). Each test that
// calls Set* must pair it with a matching Reset* in AfterEach so subsequent
// specs start from the canonical value. Running with 'ginkgo -p' is safe
// because Ginkgo parallel processes are separate OS processes and do not
// share in-process state.
package nri

func SetStateBaseDir(dir string) { stateBaseDir = dir }
func ResetStateBaseDir()         { stateBaseDir = StateBaseDir }

func SetKernelVersionFunc(fn func() (int, int)) { kernelVersionFn = fn }
func ResetKernelVersionFunc()                   { kernelVersionFn = defaultKernelVersion }

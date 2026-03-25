// export_test.go exposes internal package variables for use by the external
// test package (package nri_test). This file is compiled only during test
// runs and is invisible to non-test callers.
package nri

func SetStateBaseDir(dir string) { stateBaseDir = dir }
func ResetStateBaseDir()         { stateBaseDir = StateBaseDir }

func SetKernelVersionFunc(fn func() (int, int)) { kernelVersionFn = fn }
func ResetKernelVersionFunc()                   { kernelVersionFn = defaultKernelVersion }

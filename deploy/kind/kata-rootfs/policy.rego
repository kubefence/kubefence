package agent_policy

import future.keywords.in
import future.keywords.if

# Allow-list: all standard kata-agent requests are permitted by default.
default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := true
default SetPolicyRequest := true

# kubectl exec is allowed only when routed through the nono sandbox wrapper.
# The command must be: /nono/nono wrap --profile <name> -- <cmd ...>
# Profile names are restricted to safe identifiers (alphanumeric, hyphen,
# underscore, leading alphanumeric) to prevent CLI flag injection.
default ExecProcessRequest := false

ExecProcessRequest {
    i_command := concat(" ", input.process.Args)
    regex.match(`^/nono/nono wrap --profile [a-zA-Z0-9][a-zA-Z0-9_-]{0,63} -- .+$`, i_command)
}

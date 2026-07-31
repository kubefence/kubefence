{{/*
Expand the name of the chart.
*/}}
{{- define "kubefence.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kubefence.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kubefence.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubefence.labels" -}}
helm.sh/chart: {{ include "kubefence.chart" . }}
{{ include "kubefence.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubefence.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubefence.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
The guest extension image reference.

Defaults to the chart's own appVersion rather than a floating tag, so that
`--version 1.2.3` pins the extension to 1.2.3 the same way it pins the plugin
image. The kata-extension workflow publishes both `1.2.3` and `v1.2.3` for a
release; this uses the unprefixed one to match the plugin image's tagging.
*/}}
{{- define "kubefence.extensionImage" -}}
{{- .Values.kata.extensionImage | default (printf "ghcr.io/kubefence/kata-nono-extension:%s" .Chart.AppVersion) -}}
{{- end }}

{{/*
Shell fragment that selects the containerd plugin name a runtime handler must be
declared under, into CRI_PLUGIN.

containerd renamed the CRI runtime plugin when it introduced the version 3
config schema: handlers live under io.containerd.cri.v1.runtime there, and under
io.containerd.grpc.v1.cri in a version 2 document. The two are not
interchangeable and the mismatch is quiet — containerd parses the drop-in, logs
"Ignoring unknown key in TOML for plugin", registers nothing, and every pod using
the handler then fails with `no runtime for "<handler>" is configured`.

Both schemas are in play on supported nodes: a stock containerd 2.x config
(`containerd config default`) is version 3, while kind's node image still ships
version 2. So the name is chosen from the config being patched rather than
pinned. Expects CFG to be set.
*/}}
{{- define "kubefence.criPluginName" -}}
if grep -q '^version[[:space:]]*=[[:space:]]*3' "${CFG}"; then
  CRI_PLUGIN='io.containerd.cri.v1.runtime'
else
  CRI_PLUGIN='io.containerd.grpc.v1.cri'
fi
echo "containerd config is $(grep -m1 '^version' "${CFG}" || echo 'unversioned'); declaring handlers under ${CRI_PLUGIN}."
{{- end }}

{{/*
Shell fragment that registers the drop-in glob in containerd's imports array.

containerd only reads a drop-in directory if the glob is listed there. A stock
containerd 2.x config already lists /etc/containerd/conf.d/*.toml, in which case
this is a no-op; kind's has no imports key at all. TOML bare keys must precede
the first [table], so the key is prepended rather than appended when it has to be
created.

Shared by the node-setup and kata-setup DaemonSets, which each write their own
drop-in: two copies of this edit would be two chances to drift. Expects CFG and
DROPIN_GLOB to be set, and sets CHANGED=true if it modified anything.
*/}}
{{- define "kubefence.ensureImportsGlob" -}}
if ! grep -qF "${DROPIN_GLOB}" "${CFG}"; then
  if grep -q '^imports' "${CFG}"; then
    sed -i "s|^imports[[:space:]]*=[[:space:]]*\[|imports = [\"${DROPIN_GLOB}\", |" "${CFG}"
  else
    { printf 'imports = ["%s"]\n' "${DROPIN_GLOB}"; cat "${CFG}"; } > /tmp/ctr-cfg.toml
    cat /tmp/ctr-cfg.toml > "${CFG}"
    rm -f /tmp/ctr-cfg.toml
  fi
  # Confirm the edit landed instead of trusting it. Reporting success and
  # restarting containerd for a glob that was never added is the "registered but
  # never loaded" failure this drop-in scheme exists to rule out.
  grep -qF "${DROPIN_GLOB}" "${CFG}" || {
    echo "ERROR: could not add ${DROPIN_GLOB} to the imports array in ${CFG}; add it by hand" >&2
    exit 1
  }
  echo "Registered ${DROPIN_GLOB} in ${CFG}."
  CHANGED=true
fi
{{- end }}

function result = ex18_step_spectrum_probe(probe_data, freq_hz, step_count, pri_s, fs_hz)
%ex18_step_spectrum_probe  SFCW step-segmented spectrum analysis
%
%   Instead of FFT on the whole signal, extract the steady-state portion
%   of each frequency step (discard first 30% transient).
%
%   Inputs:
%     probe_data - timeseries, StructureWithTime, or numeric array
%     freq_hz    - Nx1 frequency axis (or [], will auto-generate)
%     step_count - number of frequency steps (or [])
%     pri_s      - PRI duration in seconds
%     fs_hz      - sample rate in Hz
%
%   Output: result struct with fields:
%     result.freq_hz          - Nx1 frequency axis
%     result.amp_db           - Nx1 amplitude (dB)
%     result.phase_rad        - Nx1 phase (radians)
%     result.complex_response - Nx1 complex response
%     result.valid            - Nx1 logical (true for valid steps)

persistent ast_meta;

% -- Resolve metadata --
if isempty(ast_meta) || nargin >= 4
    ast_meta = build_metadata(freq_hz, step_count, pri_s, fs_hz);
elseif ~isempty(ast_meta) && nargin < 4
end

meta = ast_meta;

% % -- auto-detect step_count if not provided --
% if step_count <= 0 || isempty(step_count)
%     if ~isempty(meta) && meta.step_count > 0
%         step_count = meta.step_count;
%     else
%         step_count = 501;
%     end
% end

% -- Extract time and value --
[time_s, value] = uniform_extract(probe_data);

time_s = double(time_s(:));
value = double(value(:));

n = min(numel(time_s), numel(value));
time_s = time_s(1:n);
value = value(1:n);

% -- Determine if signal is real or complex --
is_complex = ~isreal(value);

% -- Determine step parameters --
if isempty(meta) || isempty(meta.freq_hz) || meta.step_count ~= step_count
    meta = build_metadata(freq_hz, step_count, pri_s, fs_hz);
end

freq_hz = meta.freq_hz;
n_freq = numel(freq_hz);

% -- Extract steady-state portion of each step --
complex_response = complex(nan(n_freq, 1));
valid = false(n_freq, 1);

total_duration = time_s(end) - time_s(1);
est_pri = total_duration / max(step_count, 1);
pri_used = min(meta.pri_s, est_pri);

for k = 1:n_freq
    step_start = (k - 1) * pri_used;
    step_stop  = k * pri_used;

    % Steady-state window: discard first 30% transient, use middle 40-100%
    transient_end = step_start + 0.30 * pri_used;
    steady_start  = transient_end;
    steady_stop   = step_stop;

    idx = time_s >= steady_start & time_s < steady_stop;
    n_steady = nnz(idx);

    if n_steady < 4
        % Fall back to using more of the pulse
        idx = time_s >= step_start & time_s < step_stop;
        idx = idx & (time_s >= step_start + 0.10 * pri_used);
        n_steady = nnz(idx);
    end

    if n_steady < 2
        continue;
    end

    t_seg = time_s(idx);
    v_seg = value(idx);

    % For complex signals, directly average
    % For real signals, use hilbert to get analytic signal
    if is_complex
        z = v_seg;
    else
        z = hilbert(v_seg);
    end

    % Demodulate: multiply by exp(-j*2*pi*f_k*t)
    f_k = freq_hz(k);
    tone = 2 * mean(z(:) .* exp(-1i * 2 * pi * f_k * t_seg(:)));

    complex_response(k) = tone;
    valid(k) = isfinite(tone);
end

% -- Interpolate any NaN values --
if any(~valid)
    good_idx = find(valid);
    bad_idx = find(~valid);
    if numel(good_idx) >= 2
        complex_response(bad_idx) = interp1(good_idx, ...
            complex_response(good_idx), bad_idx, 'linear', 'extrap');
        valid(bad_idx) = false;
    end
end

% -- Build output --
amp = abs(complex_response);
amp_db = 20 * log10(max(amp, eps));
phase_rad = angle(complex_response);

result = struct();
result.freq_hz = freq_hz(:);
result.amp_db = amp_db(:);
result.phase_rad = phase_rad(:);
result.complex_response = complex_response(:);
result.valid = valid(:);
result.is_complex = is_complex;
end

function meta = build_metadata(freq_hz, step_count, pri_s, fs_hz)
meta = struct();
meta.step_count = max(1, round(step_count));
meta.pri_s = pri_s;
meta.fs_hz = fs_hz;

if ~isempty(freq_hz) && numel(freq_hz) > 1
    meta.freq_hz = freq_hz(:);
else
    meta.freq_hz = (1:meta.step_count).';
end
end

function [time_s, value] = uniform_extract(data)
if isa(data, 'timeseries')
    time_s = data.Time;
    value = data.Data;
elseif isstruct(data) && isfield(data, 'time') && isfield(data, 'signals')
    time_s = data.time;
    if isstruct(data.signals) && isfield(data.signals, 'values')
        value = data.signals.values;
    else
        value = data.signals;
    end
elseif isa(data, 'Simulink.SimulationData.Dataset')
    if data.numElements < 1
        error('ex18_step_spectrum_probe:EmptyDataset', 'Dataset is empty');
    end
    [time_s, value] = uniform_extract(data{1}.Values);
elseif isa(data, 'Simulink.SimulationData.Signal')
    [time_s, value] = uniform_extract(data.Values);
elseif isnumeric(data)
    value = data(:);
    time_s = (0:numel(value) - 1).';
else
    error('ex18_step_spectrum_probe:BadFormat', 'Unrecognized data format');
end

value = squeeze(value);
if ~isvector(value)
    value = value(:, 1);
end
end

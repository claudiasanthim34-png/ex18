function ex18_probe_spectrum_analysis(varargin)
%ex18_probe_spectrum_analysis  Main spectrum analysis script for probe data
%
%   Options (Name-Value):
%     'RunSimulation', false   - run sim before analysis
%     'StepCount', []          - number of frequency steps ([]=auto)
%     'SampleRate', []         - simulation sample rate ([]=default)
%     'OutputDir', 'results'   - output directory for figures
%     'Visible', 'on'          - figure visibility
%     'MaxFreqMHz', 500        - max frequency for spectrum plots
%     'PRIS', 1e-6             - PRI duration
%
%   Features:
%     1. Parse options, set up workspace
%     2. Optionally run simulation
%     3. Auto-read all probe_* variables from base workspace
%     4. Detect real vs complex signals for each probe
%     5. Generate:
%        - Individual probe spectrum figures (real: single-sided,
%          complex: double-sided fftshift)
%        - Frequency overview figure (all probe spectra overlaid)
%        - Module transfer function figures
%        - IQ demod double-sided spectra figure
%        - A-scan Delay/Depth figure
%     6. Save figures to OutputDir
%     7. Skip missing probe variables gracefully with warning

work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);

% -- Parse options --
opts = parse_probe_opts(varargin{:});

% -- Optionally run simulation --
if opts.RunSimulation
    run_preview_sim(opts);
end

% -- Ensure workspace has required variables --
if ~evalin('base', 'exist(''cfg'', ''var'')')
    setup_ex18_sfw();
end
if ~evalin('base', 'exist(''sfw_meta'', ''var'')')
    setup_ex18_sfw();
end

cfg = evalin('base', 'cfg');
freq_hz = cfg.freq.hz(:);
n_freq = numel(freq_hz);
fs_hz = cfg.time.fs_hz;
pri_s = cfg.time.pri_s;
step_count = n_freq;

% -- Create output directory --
if exist(opts.OutputDir, 'dir') ~= 7
    mkdir(opts.OutputDir);
end

% -- Define all probe variables to check --
probe_vars = {
    'probe_sfw_src',           'real';           % real RF burst
    'probe_after_coupler_main','real';           % real RF
    'probe_tap_raw',           'real';           % real RF
    'probe_before_attn',       'real';           % real RF
    'probe_after_attn',        'real';           % real RF
    'probe_before_vga',        'real';           % real RF
    'probe_after_vga',         'real';           % real RF
    'probe_before_pa',         'real';           % real RF
    'probe_after_pa',          'real';           % real RF
    'probe_tx_radiated',       'real';           % real after antenna
    'probe_after_gpr_channel', 'real';           % real GPR channel out
    'probe_rx_antenna_raw',    'real';           % real RX antenna
    'probe_tap_mixer_raw',     'real';           % real mixer product
    'probe_tap_up_bpf',        'real';           % real filtered
    'probe_rx_down_mixer_raw', 'real';           % real mixer product
    'probe_rx_down_if',        'real';           % real IF
    'probe_iq_mixer_raw',      'complex';        % complex IQ mixer out
    'probe_iq_baseband',       'complex';        % complex baseband
};

% Also try legacy variable names
legacy_vars = {
    'rf_out_log',              'real';
    'tap_up_log',              'real';
    'rx_down_if_log',          'real';
    'rx_iq_baseband_log',      'complex';
    'rx_antenna_log',          'real';
    'rf_main_out_log',         'real';
};

% -- Collect available probes --
available = {};
for i = 1:size(probe_vars, 1)
    vname = probe_vars{i,1};
    if evalin('base', sprintf('exist(''%s'', ''var'')', vname))
        available{end+1, 1} = vname;
        available{end, 2} = probe_vars{i,2};
    end
end
for i = 1:size(legacy_vars, 1)
    vname = legacy_vars{i,1};
    if evalin('base', sprintf('exist(''%s'', ''var'')', vname))
        % Only add if not already in available
        already = false;
        for j = 1:size(available, 1)
            if strcmp(available{j, 1}, vname)
                already = true;
                break;
            end
        end
        if ~already
            available{end+1, 1} = vname;
            available{end, 2} = legacy_vars{i,2};
        end
    end
end

if isempty(available)
    fprintf(['No probe variables found in base workspace. ' ...
        'Run sim(''ex18_sfw_top'') first or set RunSimulation=true.\n']);
    return;
end

fprintf('ex18 Probe Spectrum Analysis\n');
fprintf('Found %d probe variables in workspace.\n', size(available, 1));
for i = 1:size(available, 1)
    fprintf('  %s (%s)\n', available{i,1}, available{i,2});
end

% -- Step spectrum for each probe --
specs = {};
for i = 1:size(available, 1)
    vname = available{i,1};
    sig_type = available{i,2};

    raw = evalin('base', vname);
    [time_s, value] = extract_uniform(raw);

    if isempty(time_s) || isempty(value)
        fprintf('  WARN: %s is empty, skipping\n', vname);
        continue;
    end

    % Detect if actually complex
    if ~isreal(value)
        sig_type = 'complex';
    end

    % Classify based on signal content
    is_if = ~isempty(strfind(lower(vname), 'down_if'));
    is_mixer = ~isempty(strfind(lower(vname), 'mixer'));
    is_baseband = ~isempty(strfind(lower(vname), 'baseband')) ...
        || ~isempty(strfind(lower(vname), 'iq_log'));

    spec = ex18_step_spectrum_probe(raw, freq_hz, step_count, pri_s, fs_hz);
    spec.variable_name = vname;
    spec.signal_type = sig_type;
    spec.is_if = is_if;
    spec.is_mixer = is_mixer;
    spec.is_baseband = is_baseband;
    spec.time_s = time_s;
    spec.value = value;

    specs{end+1} = spec;

    % Individual probe spectrum figure
    plot_individual_probe(spec, opts);
end

% -- Overall frequency overlay --
plot_frequency_overlay(specs, opts);

% -- Module transfer functions --
plot_module_transfers(specs, opts);

% -- IQ double-sided spectrum --
plot_iq_spectrum(specs, opts);

% -- A-scan from IQ baseband --
plot_ascan_from_probe(specs, opts);

fprintf('Analysis complete. Figures saved to: %s\n', opts.OutputDir);
end

function opts = parse_probe_opts(varargin)
p = inputParser;
p.addParameter('RunSimulation', false, @(x) islogical(x) || isnumeric(x));
p.addParameter('StepCount', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
p.addParameter('SampleRate', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x)));
p.addParameter('OutputDir', fullfile(fileparts(mfilename('fullpath')), 'results'), ...
    @(x) ischar(x) || isstring(x));
p.addParameter('Visible', 'on', @(x) ischar(x) || isstring(x));
p.addParameter('MaxFreqMHz', 500, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.addParameter('PRIS', 1e-6, @(x) isnumeric(x) && isscalar(x) && x > 0);
p.parse(varargin{:});
opts = p.Results;
opts.RunSimulation = logical(opts.RunSimulation);
opts.Visible = char(opts.Visible);
opts.OutputDir = char(opts.OutputDir);
end

function run_preview_sim(opts)
model = 'ex18_sfw_top';
model_file = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);

if bdIsLoaded(model)
    close_system(model, 1);
end
load_system(model_file);

init_cmd = sprintf('setup_ex18_sfw(''StepCount'',%d,''SampleRate'',%.17g);', ...
    opts.StepCount, opts.SampleRate);
set_param(model, 'InitFcn', init_cmd);

sim(model);
fprintf('Simulation complete.\n');
end

function [time_s, value] = extract_uniform(raw)
if isa(raw, 'timeseries')
    time_s = raw.Time;
    value = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    time_s = raw.time;
    if isstruct(raw.signals) && isfield(raw.signals, 'values')
        value = raw.signals.values;
    else
        value = raw.signals;
    end
elseif isa(raw, 'Simulink.SimulationData.Dataset')
    if raw.numElements < 1
        time_s = []; value = []; return;
    end
    [time_s, value] = extract_uniform(raw{1}.Values);
elseif isa(raw, 'Simulink.SimulationData.Signal')
    [time_s, value] = extract_uniform(raw.Values);
elseif isnumeric(raw)
    value = raw(:);
    time_s = (0:numel(value)-1).';
else
    time_s = []; value = [];
end
if ~isempty(time_s)
    time_s = double(time_s(:));
    value = squeeze(double(value));
    % value may be [N 1 T] (structure with time) or [N T] after squeeze
    sz = size(value);
    if ndims(value) >= 3 || (numel(sz) >= 2 && sz(2) > 1)
        % Multi-frame: take last complete frame (most signal energy)
        value = value(:, :, end);
        value = value(:);
        % Use frame sample count, not time step count
        if numel(value) > 1
            n = numel(value);
            time_s = (0:n-1).' / max(diff(time_s(1:min(2,end))), eps);
        else
            n = min(numel(time_s), numel(value));
            value = value(1:n);
            time_s = time_s(1:n);
        end
    else
        % Single vector: truncate to match time vector length
        value = value(:);
        n = min(numel(time_s), numel(value));
        time_s = time_s(1:n);
        value = value(1:n);
    end
end
end

function plot_individual_probe(spec, opts)
vname = spec.variable_name;
sig_type = spec.signal_type;
freq = spec.freq_hz;
amp = spec.amp_db;
phase = spec.phase_rad;
time_s = spec.time_s;
value = spec.value;
fs_hz = 1 / max(diff(time_s(1:min(3, end))), eps);

max_f = opts.MaxFreqMHz * 1e6;
f_mask = freq <= max_f;

fig = figure('Name', ['Probe: ' vname], ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 1000 750]);

% Time domain
subplot(3, 1, 1);
plot(time_s * 1e9, real(value), 'b-', 'LineWidth', 0.7);
hold on;
if ~isreal(value)
    plot(time_s * 1e9, imag(value), 'r-', 'LineWidth', 0.7);
    legend('Real', 'Imag', 'Location', 'best');
end
grid on;
xlabel('Time (ns)');
ylabel('Amplitude');
title(sprintf('Time Domain: %s', vname));
xlim([0 min(200, time_s(end)*1e9)]);

% Spectrum
if strcmp(sig_type, 'complex')
    subplot(3, 1, 2);
    plot(freq / 1e6, amp, 'b-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Magnitude (dB)');
    title(sprintf('Step Spectrum: %s', vname));
    xlim([0 max_f/1e6]);

    subplot(3, 1, 3);
    plot(freq / 1e6, phase * 180 / pi, 'r-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Phase (deg)');
    title(sprintf('Phase: %s', vname));
    xlim([0 max_f/1e6]);
else
    % Single-sided FFT
    subplot(3, 1, 2);
    n = numel(value);
    if n < 4
        text(0.5, 0.5, 'Signal too short for FFT', 'Units', 'normalized', 'HorizontalAlignment', 'center');
        axis([0 1 0 1]);
    else
    nfft = 2^nextpow2(min(n, 2^20));
    win = 0.5 - 0.5 * cos(2 * pi * (0:n-1).' / max(n-1, 1));
    spec_fft = fft(real(value) .* win, nfft);
    half = floor(nfft/2) + 1;
    f_fft = (0:half-1).' * fs_hz / nfft;
    mag_fft = abs(spec_fft(1:half));
    mag_max = max(mag_fft);
    if mag_max > 0
        mag_fft_db = 20 * log10(mag_fft / mag_max);
    else
        mag_fft_db = -100 * ones(size(mag_fft));
    end
    f_mask_fft = f_fft <= max_f;
    mag_safe = mag_fft_db;
    mag_safe(isnan(mag_safe) | isinf(mag_safe)) = -100;
    plot(f_fft(f_mask_fft) / 1e6, mag_safe(f_mask_fft), 'b-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Magnitude (dB)');
    title(sprintf('FFT Spectrum: %s', vname));
    xlim([0 max_f/1e6]);
    end

    subplot(3, 1, 3);
    plot(freq / 1e6, amp, 'g-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Step Magnitude (dB)');
    title(sprintf('Step-Segmented Spectrum: %s', vname));
    xlim([0 max_f/1e6]);
end

save_figure(fig, ['probe_' vname], opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

function plot_frequency_overlay(specs, opts)
if numel(specs) < 2
    return;
end

fig = figure('Name', 'Frequency Overlay', ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 1000 600]);

colors = lines(min(numel(specs), 20));
hold on;
for i = 1:numel(specs)
    ci = mod(i-1, size(colors, 1)) + 1;
    plot(specs{i}.freq_hz / 1e6, specs{i}.amp_db, ...
        'Color', colors(ci, :), 'LineWidth', 0.8, ...
        'DisplayName', specs{i}.variable_name);
end
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dB)');
title('All Probe Spectra Overlay');
legend('Location', 'eastoutside', 'Interpreter', 'none', 'FontSize', 7);
xlim([0 opts.MaxFreqMHz]);

save_figure(fig, 'frequency_overlay', opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

function plot_module_transfers(specs, opts)
% Find pairs of input/output probes for module transfer functions
module_pairs = {
    'probe_after_coupler_main', 'probe_after_attn',  'RF_Attn';
    'probe_after_attn',         'probe_after_vga',   'RF_VGA';
    'probe_after_vga',          'probe_after_pa',    'RF_PA';
    'probe_tap_mixer_raw',      'probe_tap_up_bpf',  'Tap_Up_BPF';
    'probe_rx_down_mixer_raw',  'probe_rx_down_if',  'RX_Down_IF_BPF';
    'probe_iq_mixer_raw',       'probe_iq_baseband', 'IQ_LPF_Complex';
};

for p = 1:size(module_pairs, 1)
    in_name = module_pairs{p, 1};
    out_name = module_pairs{p, 2};
    mod_name = module_pairs{p, 3};

    in_idx = [];
    out_idx = [];
    for i = 1:numel(specs)
        if strcmp(specs{i}.variable_name, in_name)
            in_idx = i;
        end
        if strcmp(specs{i}.variable_name, out_name)
            out_idx = i;
        end
    end

    if isempty(in_idx) || isempty(out_idx)
        fprintf('  Skip transfer %s: missing probes\n', mod_name);
        continue;
    end

    % Recompute transfer function from original data
    try
        raw_in = evalin('base', in_name);
        raw_out = evalin('base', out_name);
    catch
        fprintf('  Skip transfer %s: cannot read workspace data\n', mod_name);
        continue;
    end

    ex18_module_transfer_spectrum(raw_in, raw_out, ...
        'ModuleName', mod_name, ...
        'SaveFig', true, ...
        'OutputDir', opts.OutputDir, ...
        'Visible', opts.Visible);
    fprintf('  Transfer: %s (%s->%s)\n', mod_name, in_name, out_name);
end
end

function plot_iq_spectrum(specs, opts)
% Find IQ baseband or mixer probe for double-sided spectrum
iq_spec = [];
for i = 1:numel(specs)
    if ~isempty(strfind(specs{i}.variable_name, 'iq_baseband')) || ...
       ~isempty(strfind(specs{i}.variable_name, 'iq_mixer_raw'))
        iq_spec = specs{i};
        break;
    end
end

if isempty(iq_spec) && numel(specs) >= 1
    iq_spec = specs{end};
end
if isempty(iq_spec)
    return;
end

value = iq_spec.value;
if isreal(value)
    return;
end

fs_hz = 1 / max(diff(iq_spec.time_s(1:min(3, end))), eps);
n = numel(value);
nfft = 2^nextpow2(min(n, 2^20));
win = 0.5 - 0.5 * cos(2 * pi * (0:n-1).' / max(n-1, 1));
spec_fft = fftshift(fft(value .* win, nfft));
f_fft = (-nfft/2:nfft/2-1).' * fs_hz / nfft;
mag_db = 20 * log10(max(abs(spec_fft) / max(abs(spec_fft) + eps), eps));

f_lim = 20e6;
f_mask = abs(f_fft) <= f_lim;

fig = figure('Name', 'IQ Double-Sided Spectrum', ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 900 500]);

plot(f_fft(f_mask) / 1e6, mag_db(f_mask), 'b-', 'LineWidth', 1);
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dB)');
title(sprintf('IQ Double-Sided Spectrum: %s', iq_spec.variable_name));

save_figure(fig, 'iq_doublesided_spectrum', opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

function plot_ascan_from_probe(specs, opts)
% Find IQ baseband probe for A-scan
iq_probe = [];
for i = 1:numel(specs)
    if ~isempty(strfind(specs{i}.variable_name, 'iq_baseband'))
        iq_probe = specs{i};
        break;
    end
end

if isempty(iq_probe)
    % Try probe_iq_mixer_raw as fallback
    for i = 1:numel(specs)
        if ~isempty(strfind(specs{i}.variable_name, 'iq_mixer_raw'))
            iq_probe = specs{i};
            break;
        end
    end
end

if isempty(iq_probe) || isempty(iq_probe.complex_response)
    fprintf('  Skip A-scan: no IQ baseband probe data\n');
    return;
end

% Build A-scan from complex step response
freq_hz = iq_probe.freq_hz;
response = iq_probe.complex_response;
valid = iq_probe.valid;

if nnz(valid) < 10
    fprintf('  Skip A-scan: too few valid frequency points (%d)\n', nnz(valid));
    return;
end

% Fill NaN with interpolation
bad = ~valid;
if any(bad)
    good_idx = find(valid);
    bad_idx = find(bad);
    if numel(good_idx) >= 2
        response(bad_idx) = interp1(good_idx, response(good_idx), ...
            bad_idx, 'linear', 'extrap');
    end
end

df_hz = mean(diff(freq_hz));
n_freq = numel(freq_hz);
nfft = 4096;
window = 0.5 - 0.5 * cos(2 * pi * (0:n_freq-1).' / max(n_freq-1, 1));
ascan = ifft(response .* window, nfft);
time_axis_s = (0:nfft-1).' / (nfft * df_hz);

% Try to get soil velocity
v_soil = 1e8;
try
    cfg = evalin('base', 'cfg');
    v_soil = cfg.gpr.soil_velocity_mps;
catch
end

depth_axis_m = v_soil * time_axis_s / 2;
amplitude = abs(ascan);
amp_db = 20 * log10(amplitude / max(amplitude + eps) + eps);

fig = figure('Name', 'A-scan from Probe', ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 1100 500]);

% Delay axis (ns)
subplot(1, 2, 1);
max_delay_ns = 100;
plot_mask = time_axis_s <= max_delay_ns * 1e-9;
plot(time_axis_s(plot_mask) * 1e9, amplitude(plot_mask), 'b-', 'LineWidth', 0.9);
grid on;
xlabel('Delay (ns)');
ylabel('Amplitude');
title('A-scan: Delay Domain');

% Depth axis (m)
subplot(1, 2, 2);
plot(depth_axis_m(plot_mask), amplitude(plot_mask), 'r-', 'LineWidth', 0.9);
grid on;
xlabel('Depth (m)');
ylabel('Amplitude');
title(sprintf('A-scan: Depth Domain (v=%.3g m/s)', v_soil));

% Add target markers if available
try
    cfg = evalin('base', 'cfg');
    if isfield(cfg, 'gpr') && isfield(cfg.gpr, 'targets')
        subplot(1, 2, 1);
        hold on;
        for k = 1:numel(cfg.gpr.targets)
            d = cfg.gpr.targets(k).delay_s * 1e9;
            yl = ylim;
            plot([d d], yl, 'g--', 'LineWidth', 1);
        end
        subplot(1, 2, 2);
        hold on;
        for k = 1:numel(cfg.gpr.targets)
            depth = cfg.gpr.targets(k).depth_m;
            yl = ylim;
            plot([depth depth], yl, 'g--', 'LineWidth', 1);
        end
    end
catch
end

save_figure(fig, 'ascan_from_probe', opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

function save_figure(fig, name, opts)
fname = fullfile(opts.OutputDir, ['ex18_' name '.png']);
try
    exportgraphics(fig, fname, 'Resolution', 150);
catch
    saveas(fig, fname);
end
fprintf('  Saved: %s\n', fname);
end

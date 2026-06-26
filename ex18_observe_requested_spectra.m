function ex18_observe_requested_spectra(varargin)
%ex18_observe_requested_spectra  Generate 11 spectrum observation plots for SFCW GPR.

work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);
addpath(fullfile(work_dir, 'patches'));

p = inputParser;
p.addParameter('Visible', 'on', @(x) ischar(x) || isstring(x));
p.addParameter('OutputDir', fullfile(work_dir, 'results'), @(x) ischar(x) || isstring(x));
p.parse(varargin{:});
opts = p.Results;
opts.Visible = char(opts.Visible);
opts.OutputDir = char(opts.OutputDir);

if exist(opts.OutputDir, 'dir') ~= 7, mkdir(opts.OutputDir); end

model = 'ex18_sfw_top';
model_file = fullfile(work_dir, [model '.slx']);

fprintf('=== Step 1: Apply probe patches ===\n');
if bdIsLoaded(model), close_system(model, 1); end
load_system(model_file);
if isempty(find_system(model, 'SearchDepth', 1, 'Name', 'probe_sfw_src'))
    fprintf('  Adding probes...\n');
    close_system(model, 0);
    patch_add_probes();
    load_system(model_file);
else
    fprintf('  Probes already exist.\n');
end
set_param(model, 'InitFcn', 'setup_ex18_sfw;');
save_system(model);

fprintf('=== Step 2: Run simulation ===\n');
evalin('base', sprintf('sim(''%s'')', model));
fprintf('  Simulation complete.\n');

if ~evalin('base', 'exist(''cfg'', ''var'')'), setup_ex18_sfw(); end
cfg = evalin('base', 'cfg');
freq_hz = cfg.freq.hz(:);
sim_fs = cfg.time.fs_hz;
pri_s = cfg.time.pri_s;
n_freq = numel(freq_hz);

probe_map = {
    'probe_sfw_src',            'SFW source';
    'probe_after_pa',           'Before TX antenna (PA out)';
    'probe_tx_radiated',        'After TX antenna';
    'probe_rx_antenna_raw',     'RX echo raw';
    'probe_tap_mixer_raw',      'Upconversion mixer';
    'probe_tap_up_bpf',         'Upconversion BPF upper sideband';
    'probe_rx_down_mixer_raw',  'Downconversion mixer';
    'probe_rx_down_if',         '200MHz IF';
    'probe_iq_mixer_raw',       'IQ mixer';
    'probe_iq_baseband',        'IQ baseband';
};
base_vars = evalin('base', 'who');
probes = {};
for i = 1:size(probe_map, 1)
    vname = probe_map{i, 1};
    if any(strcmp(base_vars, vname))
        try
            raw = evalin('base', vname);
            [t, v] = extract_uniform(raw);
            if ~isempty(t) && ~isempty(v) && isnumeric(v)
                decim = 1;
                if numel(v) > 10000
                    step = max(1, floor(numel(v) / 10000));
                    t = t(1:step:end); v = v(1:step:end);
                    decim = step;
                end
                need_raw = any(strcmp(vname, {'probe_iq_baseband','probe_iq_mixer_raw'}));
                probes{end+1} = struct('name', vname, 'desc', probe_map{i,2}, ...
                    'time', t, 'value', v, 'decim', decim, ...
                    'raw', iif(need_raw, raw, []));
            end
        catch ME, fprintf('  FAILED %s: %s\n', vname, ME.message); end
    end
end
fprintf('=== Step 3: Found %d probes ===\n', numel(probes));

fprintf('=== Step 4: Generate 11 plots ===\n');
pl1(probes, n_freq, pri_s, sim_fs, opts);
pl2(probes, sim_fs, opts);
pl3(probes, sim_fs, opts);
pl4(probes, sim_fs, opts);
pl5(probes, sim_fs, opts);
pl6(probes, sim_fs, opts);
pl7(probes, sim_fs, opts);
pl8(probes, sim_fs, opts);
pl9(probes, sim_fs, opts);
pl10(probes, freq_hz, opts);
pl11(probes, freq_hz, cfg, opts);

close_system(model, 0);
fprintf('=== Done: %s ===\n', opts.OutputDir);
end

function v = iif(cond, a, b)
if cond, v = a; else v = b; end
end

function idx = pidx(probes, name)
idx = 0;
for j = 1:numel(probes)
    if strcmp(probes{j}.name, name), idx = j; return; end
end
end
function ok = hasp(probes, name), ok = pidx(probes, name) > 0; end
function [t, v, d, dec] = gp(probes, name)
idx = pidx(probes, name);
if idx > 0
    t = probes{idx}.time; v = probes{idx}.value;
    d = probes{idx}.desc; dec = probes{idx}.decim;
else
    t = []; v = []; d = ''; dec = 1;
end
end
function raw = gpr(probes, name)
idx = pidx(probes, name);
if idx > 0, raw = probes{idx}.raw; else raw = []; end
end

function [t, v] = extract_uniform(raw)
if isa(raw, 'timeseries')
    t = raw.Time; v = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    t = raw.time;
    if isstruct(raw.signals) && isfield(raw.signals, 'values')
        v = raw.signals.values;
    else v = raw.signals; end
elseif isa(raw, 'Simulink.SimulationData.Dataset')
    if raw.numElements < 1, t = []; v = []; return; end
    [t, v] = extract_uniform(raw{1}.Values);
elseif isa(raw, 'Simulink.SimulationData.Signal')
    [t, v] = extract_uniform(raw.Values);
elseif isnumeric(raw)
    v = raw(:); t = (0:numel(v)-1).';
else t = []; v = []; end
if ~isempty(t)
    t = double(t(:)); v = squeeze(double(v));
    sz = size(v);
    if ndims(v) >= 3 || (numel(sz) >= 2 && sz(2) > 1)
        v = v(:, :, end); v = v(:);
        if numel(v) > 1
            t = (0:numel(v)-1).' / max(diff(t(1:min(2,end))), eps);
        end
    else
        v = v(:); n = min(numel(t), numel(v));
        t = t(1:n); v = v(1:n);
    end
end
end

function [f, m] = ssfft(v, fs, fmax)
n = numel(v);
if n < 4, f = []; m = []; return; end
nfft = 2^nextpow2(min(n, 2^16));
win = (0.5 - 0.5 * cos(2 * pi * (0:(n-1)).' ./ max(n-1, 1)));
spec = fft(real(v(:)) .* win, nfft);
h = floor(nfft/2) + 1;
f = (0:(h-1)).' .* (fs ./ nfft);
m = abs(spec(1:h));
if max(m) > 0, m = 20 .* log10(m ./ max(m)); else m(:) = -100; end
if nargin >= 3 && ~isempty(fmax)
    mask = f <= fmax; f = f(mask); m = m(mask);
end
end

function [f, m] = dsfft(v, fs, flim)
n = numel(v);
if n < 4 || isreal(v), f = []; m = []; return; end
nfft = 2^nextpow2(min(n, 2^16));
win = (0.5 - 0.5 * cos(2 * pi * (0:(n-1)).' ./ max(n-1, 1)));
spec = fftshift(fft(v(:) .* win, nfft));
f = (-nfft/2:(nfft/2-1)).' .* (fs ./ nfft);
m = abs(spec);
if max(m) > 0, m = 20 .* log10(m ./ max(m)); else m(:) = -100; end
if nargin >= 3 && ~isempty(flim)
    mask = abs(f) <= flim; f = f(mask); m = m(mask);
end
end

function sf(fig, name, opts)
fn = fullfile(opts.OutputDir, name);
try exportgraphics(fig, fn, 'Resolution', 150);
catch, saveas(fig, fn); end
fprintf('  Saved: %s\n', fn);
if strcmpi(opts.Visible, 'off'), close(fig); end
end

function pl1(probes, n_freq, pri_s, sim_fs, opts)
if ~hasp(probes, 'probe_sfw_src'), fprintf('  SKIP Fig1\n'); return; end
[t, v, ~, dec] = gp(probes, 'probe_sfw_src');
fs_eff = sim_fs / dec;
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 600]);
subplot(2,1,1);
nshow = min(50, n_freq);
n_samples = min(nshow * 10000, numel(v));
plot(t(1:n_samples) * 1e9, real(v(1:n_samples)), 'b-');
grid on; xlabel('Time (ns)'); ylabel('Amplitude');
title(sprintf('SFW source: time domain (first %d PRIs)', nshow));
subplot(2,1,2);
try
    win_len = min(256, max(64, round(numel(v)/200)));
    spectrogram(real(v), hann(win_len), round(win_len*0.75), ...
        2^nextpow2(min(win_len*4, 2048)), fs_eff, 'yaxis');
    colormap('jet'); colorbar('off'); ylim([0 500]);
    title('SFW source: spectrogram');
catch ME
    text(0.5, 0.5, ['spectrogram: ' ME.message], 'Units', 'normalized', 'HorizontalAlignment', 'center');
end
sf(fig, 'ex18_01_SFW源_时频图.png', opts);
end

function pl2(probes, sim_fs, opts)
hb = hasp(probes, 'probe_after_pa'); ha = hasp(probes, 'probe_tx_radiated');
if ~hb && ~ha, fprintf('  SKIP Fig2\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 500]);
if hb
    subplot(2,1,1);
    [~, v, ~, dec] = gp(probes, 'probe_after_pa');
    [f, m] = ssfft(v, sim_fs/dec, 500e6);
    if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('Before TX antenna (PA output)'); xlim([0 500]); end
end
if ha
    subplot(2,1,2);
    [~, v, ~, dec] = gp(probes, 'probe_tx_radiated');
    [f, m] = ssfft(v, sim_fs/dec, 500e6);
    if ~isempty(f), plot(f/1e6, m, 'r-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('After TX antenna (TX_Radiator)'); xlim([0 500]); end
end
sf(fig, 'ex18_02_发射天线前后频谱.png', opts);
end

function pl3(probes, sim_fs, opts)
nms = {'probe_rx_antenna_raw', 'probe_after_gpr_channel'}; found = '';
for i = 1:numel(nms), if hasp(probes, nms{i}), found = nms{i}; break; end; end
if isempty(found), fprintf('  SKIP Fig3\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, desc, dec] = gp(probes, found);
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title(sprintf('RX echo: %s', desc)); xlim([0 500]); end
sf(fig, 'ex18_03_接收回波原始频谱.png', opts);
end

function pl4(probes, sim_fs, opts)
if ~hasp(probes, 'probe_tap_mixer_raw'), fprintf('  SKIP Fig4\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_tap_mixer_raw');
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('Upconversion mixer wideband (Tap_Mixer_200MHz)'); xlim([0 500]);
    hold on; plot([200 200], ylim, 'r--'); text(205, max(m)*0.8, 'LO=200MHz', 'Color', 'r');
end
sf(fig, 'ex18_04_上变频混频后宽频频谱.png', opts);
end

function pl5(probes, sim_fs, opts)
if ~hasp(probes, 'probe_tap_up_bpf'), fprintf('  SKIP Fig5\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_tap_up_bpf');
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('Upconversion BPF upper sideband (210-480 MHz)'); xlim([0 500]);
    hold on; yl = ylim;
    fill([210 210 480 480], [yl(1) yl(2) yl(2) yl(1)], 'g', 'FaceAlpha', 0.08, 'EdgeColor', 'none');
    text(250, max(m)*0.85, 'Upper sideband', 'Color', 'g');
end
sf(fig, 'ex18_05_上变频滤波后上边带频谱.png', opts);
end

function pl6(probes, sim_fs, opts)
if ~hasp(probes, 'probe_rx_down_mixer_raw'), fprintf('  SKIP Fig6\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_rx_down_mixer_raw');
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('Downconversion mixer wideband (RX_Down_Mixer)'); xlim([0 500]);
    hold on; plot([200 200], ylim, 'r--'); text(205, max(m)*0.8, 'LO=200MHz', 'Color', 'r');
end
sf(fig, 'ex18_06_下变频混频后宽频频谱.png', opts);
end

function pl7(probes, sim_fs, opts)
if ~hasp(probes, 'probe_rx_down_if'), fprintf('  SKIP Fig7\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_rx_down_if');
[f, m] = ssfft(v, sim_fs/dec, 300e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('200MHz IF local spectrum (190-210 MHz)'); xlim([160 240]);
    hold on; yl = ylim;
    fill([190 190 210 210], [yl(1) yl(2) yl(2) yl(1)], 'g', 'FaceAlpha', 0.08, 'EdgeColor', 'none');
    plot([200 200], yl, 'r--'); text(201, max(m)*0.85, 'IF=200MHz', 'Color', 'r');
end
sf(fig, 'ex18_07_200MHz中频局部频谱.png', opts);
end

function pl8(probes, sim_fs, opts)
if ~hasp(probes, 'probe_iq_mixer_raw'), fprintf('  SKIP Fig8\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 900 400]);
[~, v, ~, dec] = gp(probes, 'probe_iq_mixer_raw');
[f, m] = dsfft(v, sim_fs/dec, 30e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('IQ mixer double-sided spectrum (+/-30 MHz)');
else
    [f, m] = ssfft(v, sim_fs/dec, 30e6);
    if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('IQ mixer single-sided (real signal)'); end
end
sf(fig, 'ex18_08_IQ混频后双边复频谱.png', opts);
end

function pl9(probes, sim_fs, opts)
if ~hasp(probes, 'probe_iq_baseband'), fprintf('  SKIP Fig9\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 900 400]);
[~, v, ~, dec] = gp(probes, 'probe_iq_baseband');
[f, m] = dsfft(v, sim_fs/dec, 20e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('IQ baseband double-sided spectrum (+/-20 MHz)');
    hold on; plot([0 0], ylim, 'r--');
else
    [f, m] = ssfft(v, sim_fs/dec, 20e6);
    if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('IQ baseband single-sided (real signal)'); end
end
sf(fig, 'ex18_09_IQ基带双边频谱.png', opts);
end

function pl10(probes, freq_hz, opts)
if ~hasp(probes, 'probe_iq_baseband'), fprintf('  SKIP Fig10\n'); return; end
raw = gpr(probes, 'probe_iq_baseband');
cfg_pri = 1e-6; cfg_fs = 1e9;
try c = evalin('base', 'cfg'); cfg_pri = c.time.pri_s; cfg_fs = c.time.fs_hz; catch; end
n_freq = numel(freq_hz);
spec = ex18_step_spectrum_probe(raw, freq_hz, n_freq, cfg_pri, cfg_fs);
resp = spec.complex_response; amp = spec.amp_db; ph = spec.phase_rad;
valid = spec.valid; bad = ~valid;
if any(bad)
    gd = find(valid); bd = find(bad);
    if numel(gd) >= 2
        resp(bd) = interp1(gd, resp(gd), bd, 'linear', 'extrap');
        amp(bd) = interp1(gd, amp(gd), bd, 'linear', 'extrap');
        ph(bd) = interp1(gd, ph(gd), bd, 'linear', 'extrap');
    end
end
nfft = 4096; win = 0.5 - 0.5 * cos(2*pi*(0:n_freq-1).' ./ max(n_freq-1,1));
ascan = ifft(resp .* win, nfft);
ascan_fft_mag = abs(fft(ascan, nfft));
h = floor(nfft/2) + 1;
ascan_mag_db = 20 * log10(ascan_fft_mag(1:h) / max(ascan_fft_mag(1:h) + eps) + eps);
ascan_freq = (0:h-1).' * mean(diff(freq_hz));
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 550]);
subplot(2,1,1);
yyaxis left; plot(freq_hz/1e6, amp, 'b-'); ylabel('Original Step Mag (dB)');
yyaxis right; msk = ascan_freq <= max(freq_hz);
plot(ascan_freq(msk)/1e6, ascan_mag_db(msk), 'r--'); ylabel('IFFT->FFT Mag (dB)');
grid on; xlabel('Frequency (MHz)'); title('IFFT: magnitude response comparison');
legend('Original Step', 'IFFT->FFT round-trip', 'Location', 'best');
subplot(2,1,2);
plot(freq_hz/1e6, ph*180/pi, 'r-'); grid on;
xlabel('Frequency (MHz)'); ylabel('Phase (deg)');
title('Pre-IFFT phase response (Step segmented)');
xlim([0 max(freq_hz)/1e6]);
sf(fig, 'ex18_10_IFFT前后复频响曲线.png', opts);
end

function pl11(probes, freq_hz, cfg, opts)
if ~hasp(probes, 'probe_iq_baseband'), fprintf('  SKIP Fig11\n'); return; end
raw = gpr(probes, 'probe_iq_baseband');
cfg_pri = 1e-6; cfg_fs = 1e9;
try cfg_pri = cfg.time.pri_s; cfg_fs = cfg.time.fs_hz; catch; end
n_freq = numel(freq_hz);
spec = ex18_step_spectrum_probe(raw, freq_hz, n_freq, cfg_pri, cfg_fs);
resp = spec.complex_response; valid = spec.valid;
if nnz(valid) < 10, fprintf('  SKIP Fig11: too few valid points\n'); return; end
bad = ~valid;
if any(bad)
    gd = find(valid); bd = find(bad);
    if numel(gd) >= 2, resp(bd) = interp1(gd, resp(gd), bd, 'linear', 'extrap'); end
end
df = mean(diff(freq_hz)); nfft = 4096;
win = 0.5 - 0.5 * cos(2*pi*(0:n_freq-1).' ./ max(n_freq-1,1));
ascan = ifft(resp .* win, nfft);
amp_val = abs(ascan);
t_axis = (0:nfft-1).' / (nfft * df);
v_soil = 1e8;
try v_soil = cfg.gpr.soil_velocity_mps; catch; end
d_axis = v_soil * t_axis / 2;
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 500]);
msk = t_axis <= 100e-9;
subplot(1,2,1);
plot(t_axis(msk)*1e9, amp_val(msk), 'b-'); grid on;
xlabel('Delay (ns)'); ylabel('Amplitude'); title('A-scan: Delay domain');
try
    hold on;
    for k = 1:numel(cfg.gpr.targets)
        d = cfg.gpr.targets(k).delay_s * 1e9;
        plot([d d], ylim, 'g--', 'LineWidth', 1.2);
    end
catch; end
subplot(1,2,2);
plot(d_axis(msk), amp_val(msk), 'r-'); grid on;
xlabel('Depth (m)'); ylabel('Amplitude');
title(sprintf('A-scan: Depth domain (v=%.3g m/s)', v_soil));
try
    hold on;
    for k = 1:numel(cfg.gpr.targets)
        plot([cfg.gpr.targets(k).depth_m cfg.gpr.targets(k).depth_m], ylim, 'g--', 'LineWidth', 1.2);
    end
catch; end
sf(fig, 'ex18_11_Ascan时延深度图.png', opts);
end

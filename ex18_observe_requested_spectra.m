function results = ex18_observe_requested_spectra(varargin)
%EX18_OBSERVE_REQUESTED_SPECTRA 观测 ex18 仓库中指定 RF/SFW 节点的时频图和频谱。
%
% 放置位置：建议把本文件复制到 ex18 仓库根目录，与 setup_ex18_sfw.m、ex18_sfw_top.slx 同级。
%
% 默认执行：
%   1) 自动给关键连线增加 To Workspace 探头，不修改原有信号链；
%   2) 以 2 GHz 采样率运行一次仿真，便于看见下变频混频后的宽频和频项；
%   3) 输出 SFW_Burst_Src 时域 + 时频图，以及各关键节点频谱图。
%
% 用法：
%   results = ex18_observe_requested_spectra;
%   results = ex18_observe_requested_spectra('StepCount', 80, 'Visible', 'on');
%   results = ex18_observe_requested_spectra('SampleRate', 1e9, 'MaxFreqMHz', 500);
%   results = ex18_observe_requested_spectra('RunSimulation', false); % 使用已有 workspace 日志
%
% 重点输出图：
%   01_sfw_source_time_frequency.png       SFW_Burst_Src 输出波形和时频图
%   02_tx_antenna_before_after.png         发射天线前/后的频谱叠图
%   03_rx_echo_raw_spectrum.png            接收回波原始频谱
%   04_tap_mixer_raw_wideband.png          上变频混频后的宽频频谱
%   05_tap_up_bpf_upper_sideband.png       上变频滤波后的上边带频谱
%   06_rx_down_mixer_raw_wideband.png      下变频混频后的宽频频谱
%   07_all_requested_spectra_overlay.png   关键频谱叠加总览
%
% 说明：
%   - 本脚本不依赖仓库中原来的 ex18_probe_spectrum_analysis，避免缺少 raw mixer 探头时无法画图。
%   - 若你的 MATLAB 版本较老，不支持 exportgraphics，脚本会自动退回 saveas。

opts = local_parse_opts(varargin{:});

work_dir = fileparts(mfilename('fullpath'));
if ~isempty(work_dir)
    addpath(work_dir);
    if exist(fullfile(work_dir, 'filterlib'), 'dir') == 7
        addpath(fullfile(work_dir, 'filterlib'));
    end
    if exist(fullfile(work_dir, 'dialogs'), 'dir') == 7
        addpath(fullfile(work_dir, 'dialogs'));
    end
end

if exist(opts.OutputDir, 'dir') ~= 7
    mkdir(opts.OutputDir);
end

if opts.RunSimulation
    local_prepare_model_and_run(opts);
else
    if evalin('base', 'exist(''cfg'', ''var'')') == 0
        setup_ex18_sfw('SampleRate', opts.SampleRate);
    end
end

if evalin('base', 'exist(''cfg'', ''var'')') == 0
    error('base workspace 中没有 cfg。请先运行 setup_ex18_sfw 或设置 RunSimulation=true。');
end
cfg = evalin('base', 'cfg');

% -------- 读取并绘图 --------
defs = local_requested_defs();
records = repmat(struct('Name', '', 'Variable', '', 'Kind', '', 'Time', [], ...
    'Value', [], 'FreqHz', [], 'MagDb', [], 'Figure', ''), 0, 1);

fprintf('\nex18 requested observation started. OutputDir = %s\n', opts.OutputDir);

for k = 1:numel(defs)
    def = defs(k);
    [var_name, ok] = local_first_existing(def.Candidates);
    if ~ok
        warning('跳过：%s。没有找到候选变量：%s', def.Name, strjoin(def.Candidates, ', '));
        continue;
    end

    [t, x] = local_read_workspace_signal(var_name, cfg.time.fs_hz);
    if isempty(t) || isempty(x)
        warning('跳过：%s。变量 %s 为空或格式无法识别。', def.Name, var_name);
        continue;
    end

    rec = struct();
    rec.Name = def.Name;
    rec.Variable = var_name;
    rec.Kind = def.Kind;
    rec.Time = t;
    rec.Value = x;

    if strcmp(def.Kind, 'source')
        rec.Figure = local_plot_source_time_frequency(def, var_name, t, x, cfg, opts);
        [rec.FreqHz, rec.MagDb] = local_fft_spectrum(t, x, opts, false);
    else
        [rec.FreqHz, rec.MagDb] = local_fft_spectrum(t, x, opts, false);
        rec.Figure = local_plot_single_spectrum(def, var_name, rec.FreqHz, rec.MagDb, cfg, opts);
    end

    records(end + 1, 1) = rec; %#ok<AGROW>
    fprintf('  OK %-34s <- %s\n', def.Name, var_name);
end

% -------- 发射天线前/后叠图 --------
fig_tx = local_plot_pair_overlay(records, ...
    {'发射天线前：RF_Out', '发射天线后：TX_Radiator'}, ...
    '发射天线前后频谱对比', '02_tx_antenna_before_after', cfg, opts);

% -------- 全部频谱叠加总览 --------
fig_all = local_plot_all_overlay(records, cfg, opts);

results = struct();
results.OutputDir = opts.OutputDir;
results.Options = opts;
results.Records = records;
results.Figures = unique([{records.Figure}, {fig_tx}, {fig_all}]);
results.Cfg = cfg;

save(fullfile(opts.OutputDir, 'ex18_requested_spectra_results.mat'), 'results', '-v7.3');
fprintf('Done. 已保存图片和 results.mat 到：%s\n\n', opts.OutputDir);

end

% ========================================================================
% 运行仿真并添加探头
% ========================================================================
function local_prepare_model_and_run(opts)
model = 'ex18_sfw_top';

if exist([model '.slx'], 'file') ~= 2
    if exist('build_ex18_sfw_top', 'file') == 2
        build_ex18_sfw_top();
    else
        error('找不到 %s.slx，也找不到 build_ex18_sfw_top.m。请在 ex18 仓库根目录运行。', model);
    end
end

load_system(model);
local_add_requested_probes(model);

init_cmd = local_make_init_cmd(opts);
set_param(model, 'InitFcn', init_cmd);
set_param(model, 'StopTime', 'sfw_stop_s', 'FixedStep', 'sfw_sample_s');

fprintf('Running %s ... SampleRate = %.3g Hz', model, opts.SampleRate);
if ~isempty(opts.StepCount)
    fprintf(', StepCount = %d', opts.StepCount);
end
fprintf('\n');

sim(model);
end

function init_cmd = local_make_init_cmd(opts)
args = sprintf('''SampleRate'', %.17g', opts.SampleRate);
if ~isempty(opts.StepCount)
    args = sprintf('%s, ''StepCount'', %d', args, opts.StepCount);
end
init_cmd = [ ...
    'model_dir = fileparts(get_param(bdroot, ''FileName''));' ...
    'if ~isempty(model_dir), addpath(model_dir); ' ...
    'addpath(fullfile(model_dir, ''filterlib'')); ' ...
    'addpath(fullfile(model_dir, ''dialogs'')); end;' ...
    sprintf('setup_ex18_sfw(%s);', args) ...
    ];
end

function local_add_requested_probes(model)
% 这些探头都是 Simulink 域输出端，直接从对应模块输出端分支到 To Workspace。
probes = {
    'SFW_Burst_Src/1',     'Probe_REQ_SFW_Source',      'probe_req_sfw_src',            [260 235 410 265];
    'RF_Out/1',            'Probe_REQ_TX_Before_Ant',   'probe_req_tx_before_ant',     [1200 5 1370 35];
    'TX_Radiator/1',       'Probe_REQ_TX_After_Ant',    'probe_req_tx_after_ant',      [1410 85 1580 115];
    'RX_Antenna/1',        'Probe_REQ_RX_Echo_Raw',     'probe_req_rx_echo_raw',       [1635 230 1805 260];
    'Tap_Mixer_200MHz/1',  'Probe_REQ_Tap_Mixer_Raw',   'probe_req_tap_mixer_raw',     [1270 305 1440 335];
    'Tap_Up_BPF/1',        'Probe_REQ_Tap_Up_BPF',      'probe_req_tap_up_bpf',        [1510 300 1680 330];
    'RX_Down_Mixer/1',     'Probe_REQ_RX_Down_Mixer',   'probe_req_rx_down_mixer_raw', [1885 30 2070 60];
    };

for i = 1:size(probes, 1)
    src = probes{i, 1};
    block_name = probes{i, 2};
    var_name = probes{i, 3};
    pos = probes{i, 4};
    dst = [model '/' block_name];

    old = find_system(model, 'SearchDepth', 1, 'Name', block_name);
    if ~isempty(old)
        try delete_block(dst); catch, end %#ok<CTCH>
    end

    add_block('simulink/Sinks/To Workspace', dst, ...
        'VariableName', var_name, ...
        'SaveFormat', 'Structure With Time', ...
        'Position', pos);

    try
        add_line(model, src, [block_name '/1'], 'autorouting', 'on');
    catch ME
        warning('探头连线失败：%s -> %s。原因：%s', src, block_name, ME.message);
    end
end
end

% ========================================================================
% 待观测节点定义
% ========================================================================
function defs = local_requested_defs()
defs = repmat(struct('Name', '', 'Candidates', {{}}, 'Kind', '', 'FileName', '', 'Expected', ''), 0, 1);

defs(end+1) = struct( ...
    'Name', 'SFW_Burst_Src 输出', ...
    'Candidates', {{'probe_req_sfw_src', 'probe_sfw_src', 'sfw_src_ts'}}, ...
    'Kind', 'source', ...
    'FileName', '01_sfw_source_time_frequency', ...
    'Expected', '步进频率 burst：频率随 PRI 逐步增加');

defs(end+1) = struct( ...
    'Name', '发射天线前：RF_Out', ...
    'Candidates', {{'probe_req_tx_before_ant', 'probe_after_pa', 'rf_main_out_log'}}, ...
    'Kind', 'spectrum', ...
    'FileName', '02a_tx_before_antenna_spectrum', ...
    'Expected', '主路 RF 输出，频谱应落在原始 SFW 频带');

defs(end+1) = struct( ...
    'Name', '发射天线后：TX_Radiator', ...
    'Candidates', {{'probe_req_tx_after_ant', 'probe_tx_radiated', 'rf_out_log'}}, ...
    'Kind', 'spectrum', ...
    'FileName', '02b_tx_after_antenna_spectrum', ...
    'Expected', '经发射天线后的辐射信号，频带位置应基本不变，幅度可能变化');

defs(end+1) = struct( ...
    'Name', '接收回波原始频谱', ...
    'Candidates', {{'probe_req_rx_echo_raw', 'probe_rx_antenna_raw', 'rx_antenna_log'}}, ...
    'Kind', 'spectrum', ...
    'FileName', '03_rx_echo_raw_spectrum', ...
    'Expected', 'RX_Antenna 原始输出，包含直耦、地表、杂波和目标回波');

defs(end+1) = struct( ...
    'Name', '上变频混频后宽频频谱', ...
    'Candidates', {{'probe_req_tap_mixer_raw', 'probe_tap_mixer_raw'}}, ...
    'Kind', 'spectrum', ...
    'FileName', '04_tap_mixer_raw_wideband', ...
    'Expected', 'Tap_Mixer_200MHz 后，理论上同时出现 LO+f 和 |LO-f| 成分');

defs(end+1) = struct( ...
    'Name', '上变频滤波后上边带频谱', ...
    'Candidates', {{'probe_req_tap_up_bpf', 'probe_tap_up_bpf', 'tap_up_log'}}, ...
    'Kind', 'spectrum', ...
    'FileName', '05_tap_up_bpf_upper_sideband', ...
    'Expected', 'Tap_Up_BPF 后主要保留 LO+f 上边带');

defs(end+1) = struct( ...
    'Name', '下变频混频后宽频频谱', ...
    'Candidates', {{'probe_req_rx_down_mixer_raw', 'probe_rx_down_mixer_raw'}}, ...
    'Kind', 'spectrum', ...
    'FileName', '06_rx_down_mixer_raw_wideband', ...
    'Expected', 'RX_Down_Mixer 后同时含约 200 MHz 差频 IF 和更高频和频项');
end

function [var_name, ok] = local_first_existing(candidates)
var_name = '';
ok = false;
for i = 1:numel(candidates)
    v = candidates{i};
    if evalin('base', sprintf('exist(''%s'', ''var'')', v))
        var_name = v;
        ok = true;
        return;
    end
end
end

% ========================================================================
% 工作区信号读取
% ========================================================================
function [t, x] = local_read_workspace_signal(var_name, fs_hint)
raw = evalin('base', var_name);
[t, x] = local_extract_signal(raw, fs_hint);
end

function [t, x] = local_extract_signal(raw, fs_hint)
t = [];
x = [];

if isa(raw, 'timeseries')
    t = raw.Time;
    x = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    t = raw.time;
    if isstruct(raw.signals) && isfield(raw.signals, 'values')
        x = raw.signals.values;
    else
        x = raw.signals;
    end
elseif isa(raw, 'Simulink.SimulationData.Dataset')
    if raw.numElements < 1
        return;
    end
    [t, x] = local_extract_signal(raw{1}.Values, fs_hint);
    return;
elseif isa(raw, 'Simulink.SimulationData.Signal')
    [t, x] = local_extract_signal(raw.Values, fs_hint);
    return;
elseif isnumeric(raw)
    x = raw;
    n = numel(x);
    t = (0:n-1).' / fs_hint;
else
    return;
end

if isempty(x)
    t = [];
    return;
end

t = double(t(:));
x = squeeze(x);

if ~isvector(x)
    sz = size(x);
    if ~isempty(t) && sz(1) == numel(t)
        % 多通道/多帧时取第一列，保证得到一条一维波形。
        x = reshape(x, sz(1), []);
        x = x(:, 1);
    else
        x = x(:);
        t = (0:numel(x)-1).' / fs_hint;
    end
else
    x = x(:);
end

if isempty(t)
    t = (0:numel(x)-1).' / fs_hint;
end

if numel(t) ~= numel(x)
    n = min(numel(t), numel(x));
    if n >= 2
        t = t(1:n);
        x = x(1:n);
    else
        x = x(:);
        t = (0:numel(x)-1).' / fs_hint;
    end
end

bad = isnan(real(x)) | isinf(real(x)) | isnan(imag(x)) | isinf(imag(x));
if any(bad)
    x(bad) = 0;
end
end

% ========================================================================
% 绘图：源时域 + 时频图
% ========================================================================
function fig_path = local_plot_source_time_frequency(def, var_name, t, x, cfg, opts)
fig = figure('Name', def.Name, 'Color', 'w', 'Visible', opts.Visible, ...
    'Position', [80 80 1100 720]);

subplot(2, 1, 1);
t_end = min(t(end), opts.TimePreviewUs * 1e-6);
idx = t <= t_end;
plot(t(idx) * 1e6, real(x(idx)), 'LineWidth', 0.8);
grid on;
xlabel('Time (\mus)');
ylabel('Amplitude');
title(sprintf('%s：时域步进频率 burst  (%s)', def.Name, var_name), 'Interpreter', 'none');

subplot(2, 1, 2);
max_tf_hz = min([opts.SourceTfMaxMHz * 1e6, local_get_fs(t)/2, max(cfg.freq.hz) * 1.25]);
[tf_t, tf_f, tf_db] = local_stft_map(t, x, cfg, max_tf_hz, opts);
imagesc(tf_t * 1e6, tf_f / 1e6, tf_db);
axis xy;
try
    colormap(gca, 'turbo');
catch
    colormap(gca, 'parula');
end
cb = colorbar;
ylabel(cb, 'Normalized magnitude (dB)');
xlabel('Time (\mus)');
ylabel('Frequency (MHz)');
title('SFW_Burst_Src 时频图：频率随 step 递增');

% 叠加理论 step 中心频率，便于核对时频轨迹。
hold on;
try
    n_step = min([numel(cfg.freq.hz), cfg.time.step_count]);
    step_t = ((0:n_step-1) + 0.5) * cfg.time.pri_s;
    plot(step_t * 1e6, cfg.freq.hz(1:n_step) / 1e6, 'w.', 'MarkerSize', 5);
catch
end

ylim([0 max_tf_hz / 1e6]);
fig_path = local_save_figure(fig, opts.OutputDir, def.FileName, opts);
end

% ========================================================================
% 绘图：单节点频谱
% ========================================================================
function fig_path = local_plot_single_spectrum(def, var_name, f_hz, mag_db, cfg, opts)
fig = figure('Name', def.Name, 'Color', 'w', 'Visible', opts.Visible, ...
    'Position', [100 100 1050 560]);
plot(f_hz / 1e6, mag_db, 'LineWidth', 0.85);
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dB, normalized)');
title(sprintf('%s  (%s)', def.Name, var_name), 'Interpreter', 'none');
try
    subtitle(def.Expected, 'Interpreter', 'none');
catch
    text(0.01, 0.96, def.Expected, 'Units', 'normalized', 'Interpreter', 'none', ...
        'VerticalAlignment', 'top', 'FontSize', 9);
end

xlim([0 min(opts.MaxFreqMHz, max(f_hz) / 1e6)]);
ylim([opts.YFloorDb 5]);
local_mark_expected_bands(def.Name, cfg, opts);

fig_path = local_save_figure(fig, opts.OutputDir, def.FileName, opts);
end

function fig_path = local_plot_pair_overlay(records, names, fig_title, file_name, cfg, opts)
fig_path = '';
idx = [];
for i = 1:numel(records)
    if any(strcmp(records(i).Name, names))
        idx(end+1) = i; %#ok<AGROW>
    end
end
if numel(idx) < 2
    return;
end

fig = figure('Name', fig_title, 'Color', 'w', 'Visible', opts.Visible, ...
    'Position', [120 120 1050 560]);
hold on;
for k = 1:numel(idx)
    r = records(idx(k));
    plot(r.FreqHz / 1e6, r.MagDb, 'LineWidth', 0.95, 'DisplayName', r.Name);
end
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dB, normalized)');
title(fig_title);
legend('Location', 'best', 'Interpreter', 'none');
xlim([0 min(opts.MaxFreqMHz, max(records(idx(1)).FreqHz) / 1e6)]);
ylim([opts.YFloorDb 5]);
local_mark_expected_bands('发射天线前后', cfg, opts);
fig_path = local_save_figure(fig, opts.OutputDir, file_name, opts);
end

function fig_path = local_plot_all_overlay(records, cfg, opts)
fig_path = '';
if isempty(records)
    return;
end
fig = figure('Name', 'All requested spectra overlay', 'Color', 'w', 'Visible', opts.Visible, ...
    'Position', [140 140 1150 640]);
hold on;
for i = 1:numel(records)
    if isempty(records(i).FreqHz) || strcmp(records(i).Kind, 'source')
        continue;
    end
    plot(records(i).FreqHz / 1e6, records(i).MagDb, 'LineWidth', 0.8, ...
        'DisplayName', records(i).Name);
end
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dB, normalized)');
title('所有指定观测点频谱叠加总览');
legend('Location', 'eastoutside', 'Interpreter', 'none', 'FontSize', 8);
xlim([0 min(opts.MaxFreqMHz, local_get_fs(records(1).Time)/2/1e6)]);
ylim([opts.YFloorDb 5]);
local_mark_expected_bands('总览', cfg, opts);
fig_path = local_save_figure(fig, opts.OutputDir, '07_all_requested_spectra_overlay', opts);
end

% ========================================================================
% 频谱与时频计算
% ========================================================================
function [f_hz, mag_db] = local_fft_spectrum(t, x, opts, two_sided)
fs = local_get_fs(t);
x = x(:);

% 控制 FFT 点数，信号太长时等间隔抽样，避免图太慢。
if numel(x) > opts.MaxSamplesForFFT
    stride = ceil(numel(x) / opts.MaxSamplesForFFT);
    x = x(1:stride:end);
    fs = fs / stride;
end

x = x - mean(x);
n = numel(x);
if n < 4
    f_hz = 0;
    mag_db = opts.YFloorDb;
    return;
end

win = local_hann(n);
nfft = 2 ^ nextpow2(min(max(n, 1024), opts.MaxNFFT));
X = fft(x .* win, nfft);

if two_sided
    X = fftshift(X);
    f_hz = ((-nfft/2):(nfft/2-1)).' * fs / nfft;
    mag = abs(X(:));
else
    half = floor(nfft / 2) + 1;
    X = X(1:half);
    f_hz = (0:half-1).' * fs / nfft;
    mag = abs(X(:));
end

mag = mag / max(sum(win), eps);
mag_db = 20 * log10(mag + eps);
if opts.NormalizeToPeak
    mag_db = mag_db - max(mag_db);
end
mag_db(mag_db < opts.YFloorDb) = opts.YFloorDb;

max_hz = min(opts.MaxFreqMHz * 1e6, fs / 2);
mask = f_hz >= 0 & f_hz <= max_hz;
f_hz = f_hz(mask);
mag_db = mag_db(mask);
end

function [tmid, f, db] = local_stft_map(t, x, cfg, max_hz, opts)
fs = local_get_fs(t);
x = real(x(:));
x = x - mean(x);
n = numel(x);

win_len = max(64, round(0.50 * cfg.time.pri_s * fs));
win_len = min(win_len, n);
hop = max(1, round(0.50 * cfg.time.pri_s * fs));

% 限制帧数，避免全 501 step 时图片过大。
max_frames = opts.MaxSTFTFrames;
if n > win_len
    raw_frames = floor((n - win_len) / hop) + 1;
    if raw_frames > max_frames
        hop = ceil((n - win_len) / max(max_frames - 1, 1));
    end
end

nfft = 2 ^ nextpow2(max(win_len, 512));
win = local_hann(win_len);
f_all = (0:floor(nfft/2)).' * fs / nfft;
f_mask = f_all <= max_hz;
f = f_all(f_mask);

starts = 1:hop:(n - win_len + 1);
S = zeros(numel(f), numel(starts));
tmid = zeros(1, numel(starts));

for k = 1:numel(starts)
    ii = starts(k):(starts(k) + win_len - 1);
    X = fft(x(ii) .* win, nfft);
    A = abs(X(1:numel(f_all)));
    S(:, k) = A(f_mask);
    tmid(k) = mean(t(ii));
end

db = 20 * log10(S + eps);
db = db - max(db(:));
db(db < opts.TFFloorDb) = opts.TFFloorDb;
end

function fs = local_get_fs(t)
if numel(t) >= 3
    dt = median(diff(t));
    fs = 1 / max(dt, eps);
else
    fs = 1;
end
end

function w = local_hann(n)
if n <= 1
    w = 1;
else
    w = 0.5 - 0.5 * cos(2*pi*(0:n-1).'/(n-1));
end
end

% ========================================================================
% 频带标记
% ========================================================================
function local_mark_expected_bands(name, cfg, opts)
hold on;
yl = ylim;

% 原始 SFW 频带
try
    local_draw_band(cfg.freq.hz(1) / 1e6, cfg.freq.hz(end) / 1e6, yl, 'SFW');
catch
end

% 200 MHz 本振
try
    local_draw_vline(cfg.tap_mixer.lo_hz / 1e6, yl, 'LO');
catch
end

% 上边带 / 上变频 BPF / IF 带宽
lower_name = lower(name);
if contains(lower_name, '上变频') || contains(lower_name, 'tap') || contains(lower_name, '总览')
    try
        local_draw_band(cfg.tap_mixer.upper_sideband_hz(1) / 1e6, ...
            cfg.tap_mixer.upper_sideband_hz(2) / 1e6, yl, 'LO+f');
    catch
    end
    try
        local_draw_band(cfg.tap_mixer.up_bpf_hz(1) / 1e6, ...
            cfg.tap_mixer.up_bpf_hz(2) / 1e6, yl, 'Up BPF');
    catch
    end
end

if contains(lower_name, '下变频') || contains(lower_name, 'down') || contains(lower_name, '总览')
    try
        local_draw_band(cfg.down_mixer.if_bpf_hz(1) / 1e6, ...
            cfg.down_mixer.if_bpf_hz(2) / 1e6, yl, 'IF');
    catch
    end
end

ylim(yl);
xlim([0 min(opts.MaxFreqMHz, xlim_max_safe())]);
end

function xmax = xlim_max_safe()
xl = get(gca, 'XLim');
xmax = xl(2);
end

function local_draw_vline(x, yl, label_text)
if ~isfinite(x)
    return;
end
line([x x], yl, 'LineStyle', '--', 'LineWidth', 0.8, 'Color', [0.2 0.2 0.2], ...
    'HandleVisibility', 'off');
text(x, yl(2), [' ' label_text], 'Rotation', 90, 'VerticalAlignment', 'top', ...
    'FontSize', 8, 'Color', [0.2 0.2 0.2], 'HandleVisibility', 'off');
end

function local_draw_band(x1, x2, yl, label_text)
if ~isfinite(x1) || ~isfinite(x2)
    return;
end
x1 = max(0, min(x1, x2));
x2 = max(x1, max(x1, x2));
if x2 <= x1
    return;
end
p = patch([x1 x2 x2 x1], [yl(1) yl(1) yl(2) yl(2)], [0.85 0.85 0.85], ...
    'FaceAlpha', 0.18, 'EdgeColor', 'none', 'HandleVisibility', 'off');
uistack(p, 'bottom');
text((x1+x2)/2, yl(1) + 0.08*(yl(2)-yl(1)), label_text, ...
    'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', [0.25 0.25 0.25], ...
    'HandleVisibility', 'off');
end

% ========================================================================
% 工具函数
% ========================================================================
function fig_path = local_save_figure(fig, out_dir, file_name, opts)
fig_path = fullfile(out_dir, [file_name '.png']);
try
    exportgraphics(fig, fig_path, 'Resolution', opts.ResolutionDPI);
catch
    saveas(fig, fig_path);
end
if opts.SaveFigFile
    try
        savefig(fig, fullfile(out_dir, [file_name '.fig']));
    catch
    end
end
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

function opts = local_parse_opts(varargin)
p = inputParser;
p.FunctionName = 'ex18_observe_requested_spectra';
addParameter(p, 'RunSimulation', true, @(x)islogical(x) || isnumeric(x));
addParameter(p, 'SampleRate', 2e9, @(x)isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'StepCount', [], @(x)isempty(x) || (isnumeric(x) && isscalar(x) && x >= 1));
addParameter(p, 'OutputDir', fullfile('output', 'ex18_requested_spectra'), @(x)ischar(x) || isstring(x));
addParameter(p, 'Visible', 'on', @(x)ischar(x) || isstring(x));
addParameter(p, 'MaxFreqMHz', 900, @(x)isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'SourceTfMaxMHz', 320, @(x)isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'TimePreviewUs', 8, @(x)isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'NormalizeToPeak', true, @(x)islogical(x) || isnumeric(x));
addParameter(p, 'YFloorDb', -100, @(x)isnumeric(x) && isscalar(x));
addParameter(p, 'TFFloorDb', -80, @(x)isnumeric(x) && isscalar(x));
addParameter(p, 'MaxSamplesForFFT', 2^20, @(x)isnumeric(x) && isscalar(x) && x >= 1024);
addParameter(p, 'MaxNFFT', 2^20, @(x)isnumeric(x) && isscalar(x) && x >= 1024);
addParameter(p, 'MaxSTFTFrames', 1200, @(x)isnumeric(x) && isscalar(x) && x >= 10);
addParameter(p, 'ResolutionDPI', 220, @(x)isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'SaveFigFile', false, @(x)islogical(x) || isnumeric(x));
parse(p, varargin{:});
opts = p.Results;
opts.RunSimulation = logical(opts.RunSimulation);
opts.NormalizeToPeak = logical(opts.NormalizeToPeak);
opts.SaveFigFile = logical(opts.SaveFigFile);
opts.OutputDir = char(opts.OutputDir);
opts.Visible = char(opts.Visible);
if ~isempty(opts.StepCount)
    opts.StepCount = round(opts.StepCount);
end
end

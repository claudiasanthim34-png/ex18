function results = ex18_plot_scope_spectra(varargin)
%EX18_PLOT_SCOPE_SPECTRA 绘制 ex18 SFCW GPR 各观测点的时域波形和频谱。
%
%   【功能概述】
%   本脚本遍历 ex18 射频链路中的 7 个观测点，从 base workspace 读取已有日志信号，
%   对每个信号绘制两幅子图：时域波形（前若干 ns）和单边功率谱（到指定最大频率）。
%   不依赖 Simulink 运行时 Scope，可离线做频谱分析。
%
%   【SFCW 链路观测点一览（从前往后）】
%     1. Scope_SFW_Source     — 发射端 SFCW burst（复数基带），源信号参考
%     2. Scope_RF_Main_Out    — 经过衰减器+可调放大器+LNA+功率放大器后的主路输出
%     3. Scope_TX_Radiated    — TX_Radiator：经天线辐射到地下的合路信号
%     4. RX_Antenna raw       — 接收天线原始输出（含直耦/地表/杂波/目标回波）
%     5. Scope_Tap_Upconverted— 耦合支路经 Tap_Mixer 200MHz 上变频后的信号
%     6. Scope_RX_Down_IF     — 接收通道与上变频支路混频后的中频信号
%     7. Scope_RX_IQ_Baseband — I/Q 正交解调+低通滤波后的复数基带信号
%
%   【使用方法】
%     results = ex18_plot_scope_spectra()
%       使用 base workspace 中已有的日志信号绘图。需先手动运行一次仿真。
%
%     results = ex18_plot_scope_spectra('RunSimulation', true, 'StepCount', 2)
%       先运行一个短仿真（只发 2 个频点），再绘图。适合快速预览频谱。
%
%     results = ex18_plot_scope_spectra('SaveFigures', false, 'Visible', 'on')
%       不保存图像文件，弹出交互式图窗。
%
%   【输出字段 results】
%     .signals      — 结构体数组，每个信号包含 rms/峰值频率/采样率等摘要信息
%     .figures      — 保存的图像文件路径列表
%     .missing      — 因变量缺失而跳过的观测点及原因
%     .output_dir   — 图像输出目录
%
%   【注意事项】
%     - 本脚本只读 base workspace 中的变量，不会修改或保存 ex18_sfw_top.slx。
%     - 采样率过高时（如 1GHz），自动降采样（stride）以避免 FFT 点数过大。

% =========================================================================
% 主入口
% =========================================================================

work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);

% --- 1. 解析命令行参数 ---
opts = parse_opts(varargin{:});
opts.Timestamp = datestr(now, 'yyyymmdd_HHMMSS');

% --- 2. 可选：先运行短仿真，产生日志数据 ---
if opts.RunSimulation
    run_preview_simulation(opts);
end

% --- 3. 建立 7 个观测点的信号定义（每个定义包含：名称/变量名/预期频带） ---
defs = make_signal_defs();

% --- 4. 确保输出目录存在 ---
if opts.SaveFigures && exist(opts.OutputDir, 'dir') ~= 7
    mkdir(opts.OutputDir);
end

% --- 5. 初始化结果结构体 ---
results = struct();
results.output_dir = opts.OutputDir;
results.signals = struct([]);     % 成功绘制的信号摘要
results.figures  = {};            % 保存的图像文件路径
results.missing  = struct([]);    % 因变量缺失而跳过的观测点

% --- 6. 遍历每个观测点，读取日志 → 绘图 → 收集摘要 ---
fprintf('ex18 offline scope/spectrum analysis\n');
for k = 1:numel(defs)
    def = defs(k);

    % 6a. 检查变量是否存在，不存在则记录到 missing
    if ~base_has_var(def.VariableName)
        missing = struct('Scope', def.Scope, ...
            'VariableName', def.VariableName, ...
            'Reason', def.MissingReason);
        if isempty(results.missing)
            results.missing = missing;
        else
            results.missing(end + 1) = missing; %#ok<AGROW>
        end
        fprintf('  skip %-24s: missing %s\n', def.Scope, def.VariableName);
        continue;
    end

    % 6b. 从 base workspace 读取信号变量
    raw = evalin('base', def.VariableName);

    % 6c. 统一提取时间轴和数值（兼容 timeseries / struct / Dataset 等格式）
    [time_s, value] = extract_signal(raw, def.VariableName);

    % 6d. 绘图：时域波形 + 频谱，返回信号摘要
    summary = plot_signal(def, time_s, value, opts);

    % 6e. 积累结果
    if isempty(results.signals)
        results.signals = summary;
    else
        results.signals(end + 1) = summary; %#ok<AGROW>
    end
    if ~isempty(summary.FigureFile)
        results.figures{end + 1} = summary.FigureFile; %#ok<AGROW>
    end

    % 6f. 打印该信号的关键指标
    fprintf('  %-24s rms = %.4g, peak ~= %.3f MHz\n', ...
        def.Scope, summary.RMS, summary.PeakFrequencyHz / 1e6);
end

% --- 7. 输出汇总信息 ---
if isempty(results.signals)
    fprintf(['No available signal variables were found. Run sim(''ex18_sfw_top'') first, ' ...
        'or call ex18_plot_scope_spectra(''RunSimulation'', true, ''StepCount'', 2).\n']);
end

if ~isempty(results.missing)
    fprintf('\nMissing offline observations:\n');
    for k = 1:numel(results.missing)
        fprintf('  %s: %s\n', results.missing(k).Scope, results.missing(k).Reason);
    end
end
end

%% ========================================================================
% 参数解析
% ========================================================================
function opts = parse_opts(varargin)
%PARSE_OPTS 解析本脚本的配置参数。所有参数均支持名-值对方式传入。
%
%   命令行临时覆盖示例：
%     ex18_plot_scope_spectra('TimeSpanNs', 500, 'MaxFrequencyMHz', 300)

% ===== 手动配置区 —— 直接修改下面的数值即可改变默认值 =====
cfg_auto_RunSimulation   = false;    % 是否自动运行短仿真
cfg_auto_StepCount       = 2;        % 短仿真使用的频点数量
cfg_auto_StartIndex      = 1;        % 短仿真起始频点索引
cfg_auto_SampleRate      = [];       % 空 = 使用 setup 默认采样率；填数值则覆盖
cfg_auto_TimeSpanNs      = 200;      % 时域图横轴显示范围，单位 ns
cfg_auto_MaxFrequencyMHz = 500;      % 频谱图横轴最大频率，单位 MHz
cfg_auto_MaxSamples      = 2e6;      % 降采样后最大时域样本数（防止内存过大）
cfg_auto_MaxFftSamples   = 2^20;     % FFT 最大点数（2^20 ≈ 1M）
cfg_auto_SaveFigures     = true;     % 是否保存图像
cfg_auto_Visible         = 'on';     % 'on'=弹出图窗，'off'=静默绘图

parser = inputParser;
parser.addParameter('RunSimulation',   cfg_auto_RunSimulation,   @(x) islogical(x) || isnumeric(x));
parser.addParameter('StepCount',       cfg_auto_StepCount,       @(x) isnumeric(x) && isscalar(x) && x >= 1);
parser.addParameter('StartIndex',      cfg_auto_StartIndex,      @(x) isnumeric(x) && isscalar(x) && x >= 1);
parser.addParameter('SampleRate',      cfg_auto_SampleRate,      @(x) isempty(x) || ...
    (isnumeric(x) && isscalar(x) && x > 0));
parser.addParameter('TimeSpanNs',      cfg_auto_TimeSpanNs,      @(x) isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('MaxFrequencyMHz', cfg_auto_MaxFrequencyMHz, @(x) isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('MaxSamples',      cfg_auto_MaxSamples,      @(x) isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('MaxFftSamples',   cfg_auto_MaxFftSamples,   @(x) isnumeric(x) && isscalar(x) && x > 0);
parser.addParameter('SaveFigures',     cfg_auto_SaveFigures,     @(x) islogical(x) || isnumeric(x));
parser.addParameter('Visible',         cfg_auto_Visible,         @(x) ischar(x) || isstring(x));
parser.addParameter('OutputDir', fullfile(fileparts(mfilename('fullpath')), 'output'), ...
    @(x) ischar(x) || isstring(x));
parser.parse(varargin{:});
opts = parser.Results;

% 类型归一化：确保逻辑/整数等类型正确
opts.RunSimulation = logical(opts.RunSimulation);
opts.StepCount     = max(1, round(opts.StepCount));
opts.StartIndex    = max(1, round(opts.StartIndex));
opts.MaxSamples    = max(1, round(opts.MaxSamples));
opts.MaxFftSamples = max(1, round(opts.MaxFftSamples));
opts.SaveFigures   = logical(opts.SaveFigures);
opts.Visible       = char(opts.Visible);
opts.OutputDir     = char(opts.OutputDir);
end

%% ========================================================================
% 短仿真（自动产生日志数据）
% ========================================================================
function run_preview_simulation(opts)
%RUN_PREVIEW_SIMULATION 临时运行一次短仿真以产生日志信号。
%
%   【操作流程】
%     1. 记录模型当前的 InitFcn 和 Dirty 状态
%     2. 临时把 InitFcn 改成只发 StepCount 个频点的 setup
%     3. 运行 sim()，并把 To Workspace 日志复制到 base workspace
%     4. 自动恢复模型原 InitFcn 和 Dirty（onCleanup 保证即使出错也恢复）
%
%   【特性】不对 .slx 文件做永久修改，不改变用户的手动电路排列。

model = 'ex18_sfw_top';
model_file = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);
load_system(model_file);

% 保存模型原始状态，onCleanup 保证出错退出时自动恢复
old_init  = get_param(model, 'InitFcn');
old_dirty = get_param(model, 'Dirty');
cleanup = onCleanup(@() restore_model_init(model, old_init, old_dirty));

% 构造临时 InitFcn：仅发射 StepCount 个频点，起始于 StartIndex
init_cmd = sprintf('setup_ex18_sfw(''StepCount'', %d, ''StartIndex'', %d);', ...
    opts.StepCount, opts.StartIndex);

% 若用户指定了采样率覆盖，也写入临时 InitFcn
if ~isempty(opts.SampleRate)
    init_cmd = sprintf(['setup_ex18_sfw(''StepCount'', %d, ' ...
        '''StartIndex'', %d, ''SampleRate'', %.17g);'], ...
        opts.StepCount, opts.StartIndex, opts.SampleRate);
end

set_param(model, 'InitFcn', init_cmd);

% 运行仿真。ReturnWorkspaceOutputs='on' 让 To Workspace 日志进入 sim_out
sim_out = sim(model, 'ReturnWorkspaceOutputs', 'on');

% 将 sim_out 中的关键日志变量复制到 base workspace，供后续绘图使用
copy_sim_outputs_to_base(sim_out);
end

function copy_sim_outputs_to_base(sim_out)
%COPY_SIM_OUTPUTS_TO_BASE 从 sim_out 中提取日志变量并写入 base workspace。
%
%   【说明】Simulink 使用 ReturnWorkspaceOutputs='on' 后，To Workspace 块的
%   输出出现在 sim_out 对象中而不是 base workspace。这里主动复制一份以便
%   主循环的 evalin('base', ...) 可以读取。

% 需要复制的日志变量名列表（对应模型中的 To Workspace 块）
names = {'rf_main_out_log', 'rf_out_log', 'tap_up_log', ...
    'rx_down_if_log', 'rx_final_mixed_log', 'rx_antenna_log'};

for k = 1:numel(names)
    try
        value = sim_out.get(names{k});     % 从 sim_out 提取
    catch
        continue;                          % 该变量不存在则跳过
    end
    assignin('base', names{k}, value);     % 写入 base workspace
end
end

function restore_model_init(model, old_init, old_dirty)
%RESTORE_MODEL_INIT 恢复模型原始的 InitFcn 和 Dirty 标志。
%   由 onCleanup 自动调用，保证即使仿真出错也不会污染模型文件。

if bdIsLoaded(model)
    set_param(model, 'InitFcn', old_init);
    set_param(model, 'Dirty', old_dirty);
end
end

%% ========================================================================
% 信号定义 — 7 个观测点的元数据
% ========================================================================
function defs = make_signal_defs()
%MAKE_SIGNAL_DEFS 构建 7 个观测点的信号定义结构体数组。
%
%   【每个定义包含】
%     Scope            — 观测点显示名称
%     Title            — 图窗标题用
%     VariableName     — base workspace 中的变量名
%     ExpectedBandHz   — 预期信号频率范围 [f_min, f_max]，用于频谱图上高亮
%     MissingReason    — 变量缺失时的提示信息

% 获取各观测点的预期频带
src_band = get_source_band();           % 发射源频带 → 20~270 MHz
tap_band = get_base_vector('tap_up_bpf_hz', [220e6 370e6]);
                                        % 上变频带通频带
if_band = get_base_vector('rx_down_if_bpf_hz', [150e6 250e6]);
                                        % 中频带通频带
iq_band = get_base_vector('iq_lpf_cutoff_hz', [10e6]);
iq_band = [0, iq_band(1)];             % I/Q 基带从 DC 到低通截止

% ----- 7 个观测点 -----
defs = [ ...
    % 1. SFCW burst 源信号（复数基带，未经过任何射频链路）
    make_def('Scope_SFW_Source', 'SFW source', 'sfw_src_ts', src_band, ...
    'Run setup_ex18_sfw first so sfw_src_ts exists.'), ...

    % 2. 射频主路输出（衰减器 → VGA → PA 之后，辐射之前）
    make_def('Scope_RF_Main_Out', 'RF main output', 'rf_main_out_log', src_band, ...
    'Run sim(''ex18_sfw_top'') first so Scope_RF_Main_Out data logging exists.'), ...

    % 3. 天线辐射信号（经 TX_Radiator 发射到地下的实际波形）
    make_def('Scope_TX_Radiated', 'TX radiated', 'rf_out_log', src_band, ...
    'Run sim(''ex18_sfw_top'') first so rf_out_log exists.'), ...

    % 4. 接收天线原始输出（含直耦+地表+杂波+目标回波，未经任何接收链路处理）
    make_def('RX_Antenna raw', 'RX antenna raw', 'rx_antenna_log', src_band, ...
    'Run sim(''ex18_sfw_top'') first so rx_antenna_log exists.'), ...

    % 5. 耦合支路上变频后（经 Tap_Mixer 混频到 200MHz 上方，再经 Tap_Up_BPF 滤波）
    make_def('Scope_Tap_Upconverted', 'Tap upconverted', 'tap_up_log', tap_band, ...
    'Run sim(''ex18_sfw_top'') first so tap_up_log exists.'), ...

    % 6. 接收下变频中频（天线信号与上变频支路混频后的差频 ≈ 200MHz，经 IF_BPF 滤波）
    make_def('Scope_RX_Down_IF', 'RX downconverted IF', 'rx_down_if_log', if_band, ...
    'Run sim(''ex18_sfw_top'') first so rx_down_if_log exists.'), ...

    % 7. I/Q 解调复数基带（I/Q 正交混频+低通后的 DC~10MHz 基带）
    make_def('Scope_RX_IQ_Baseband', 'RX IQ baseband', 'rx_iq_baseband_log', iq_band, ...
    'Run sim(''ex18_sfw_top'') first so rx_iq_baseband_log exists.') ...
    ];
end

function def = make_def(scope, title_text, var_name, band_hz, missing_reason)
%MAKE_DEF 创建单个观测点的信号定义结构体。

def = struct();
def.Scope          = scope;           % 观测点名称（与 Simulink Scope 块名对应）
def.Title          = title_text;      % 图窗标题显示文本
def.VariableName   = var_name;        % base workspace 中的变量名
def.ExpectedBandHz = band_hz(:).';    % 预期频率范围 [f_min f_max]
def.MissingReason  = missing_reason;  % 变量缺失时的说明
end

%% ========================================================================
% 辅助工具：base workspace 读/查
% ========================================================================
function band_hz = get_source_band()
%GET_SOURCE_BAND 获取 SFCW 发射源频带 [f_min, f_max]。
%   优先从 sfw_meta 读取，缺省回退到 setup 中定义的 sfw_freq_hz。

freq_hz = [];
if base_has_var('sfw_meta')
    meta = evalin('base', 'sfw_meta');
    if isstruct(meta) && isfield(meta, 'freq_hz')
        freq_hz = meta.freq_hz;
    end
end
if isempty(freq_hz)
    freq_hz = get_base_vector('sfw_freq_hz', [20e6 170e6]);
end
band_hz = [min(freq_hz(:)) max(freq_hz(:))];
end

function value = get_base_vector(name, fallback)
%GET_BASE_VECTOR 从 base workspace 取向量变量，缺失时使用 fallback 默认值。

if base_has_var(name)
    value = evalin('base', name);
else
    value = fallback;
end
value = value(:).';    % 强制转为行向量
end

function tf = base_has_var(name)
%BASE_HAS_VAR 判断 base workspace 中是否存在指定变量。

tf = evalin('base', sprintf('exist(''%s'', ''var'') == 1', name));
end

%% ========================================================================
% 信号提取 — 兼容多种 Simulink 日志格式
% ========================================================================
function [time_s, value] = extract_signal(raw, var_name)
%EXTRACT_SIGNAL 统一解析 Simulink 日志信号格式。
%
%   【支持的格式】
%     - timeseries          （最常用，Scope 数据记录）
%     - Structure With Time  （To Workspace 块默认格式）
%     - Dataset / Signal    （Simulink.SimulationData 对象）
%     - 纯数值数组           （无时间轴时，默认采样间隔为 1）
%
%   【输出】
%     time_s : 时间列向量 (s)
%     value  : 信号值列向量（可能为复数）

% ---- 格式分支 ----
if isa(raw, 'timeseries')
    % 标准 timeseries 格式
    time_s = raw.Time;
    value  = raw.Data;

elseif isa(raw, 'Simulink.SimulationData.Dataset')
    % Dataset 格式：取第一个元素递归解析
    if raw.numElements < 1
        error('ex18_plot_scope_spectra:EmptyDataset', ...
            '%s is an empty Dataset.', var_name);
    end
    [time_s, value] = extract_signal(raw{1}.Values, var_name);
    return;

elseif isa(raw, 'Simulink.SimulationData.Signal')
    % Signal 格式：取 Values 字段递归解析
    [time_s, value] = extract_signal(raw.Values, var_name);
    return;

elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    % Structure With Time 格式（To Workspace 块 SaveFormat='Structure With Time'）
    time_s = raw.time;
    if isstruct(raw.signals) && isfield(raw.signals, 'values')
        value = raw.signals.values;
    else
        error('ex18_plot_scope_spectra:BadLog', ...
            '%s.signals.values was not found.', var_name);
    end

elseif isnumeric(raw)
    % 纯数值：无时间轴，假设采样间隔为 1
    value  = raw;
    time_s = (0:numel(value) - 1).';

else
    error('ex18_plot_scope_spectra:BadSignal', ...
        'Unsupported signal format for %s.', var_name);
end

% ---- 后处理：统一维度、去除非法值 ----
time_s = double(time_s(:));
value  = squeeze(value);                    % 去除单维度

if isempty(value)
    value = zeros(size(time_s));
end

% 若为多列矩阵，取第 1 列
if ~isvector(value)
    if size(value, 1) ~= numel(time_s) && size(value, 2) == numel(time_s)
        value = value.';
    end
    value = reshape(value, size(value, 1), []);
    value = value(:, 1);
end
value = double(value(:));

% 对齐时间轴和信号长度
n = min(numel(time_s), numel(value));
time_s = time_s(1:n);
value  = value(1:n);

% 去除 NaN / Inf
finite_idx = isfinite(time_s) & isfinite(real(value)) & isfinite(imag(value));
time_s = time_s(finite_idx);
value  = value(finite_idx);
end

%% ========================================================================
% 核心绘图 — 时域波形 + 频谱
% ========================================================================
function summary = plot_signal(def, time_s, value, opts)
%PLOT_SIGNAL 为单个信号绘制时域/频谱双视图并计算信号摘要。
%
%   【输出 subplot 布局（上下排列）】
%     上图：时域波形（截取前 TimeSpanNs 的片段）
%     下图：单边功率谱（幅度归一化后用 dB 表示）
%
%   【关键步骤】
%     1. 自适应降采样（stride）— 避免 1GHz 采样率时 FFT 点数过大
%     2. Hann 窗 + FFT 计算频谱
%     3. 在预期频带内寻找峰值频率

if numel(time_s) < 2
    error('ex18_plot_scope_spectra:ShortSignal', ...
        '%s has fewer than two samples.', def.VariableName);
end

% --- 1. 自适应降采样，减少 FFT 点数 ---
[spec_t_s, spec_value, fs_hz, stride] = prepare_spectrum_signal(time_s, value, opts);

% --- 2. 加窗 FFT → 单边幅度谱 (dB) ---
[freq_hz, mag_db] = compute_single_sided_spectrum(spec_value, fs_hz, opts);

% --- 3. 在 MaxFrequencyMHz 范围内寻找峰值频率 ---
max_freq_hz = opts.MaxFrequencyMHz * 1e6;
freq_mask = freq_hz <= max_freq_hz;
if any(freq_mask)
    freq_for_peak = freq_hz(freq_mask);
    mag_for_peak  = mag_db(freq_mask);
else
    freq_for_peak = freq_hz;
    mag_for_peak  = mag_db;
end
[~, peak_idx] = max(mag_for_peak);
peak_hz = freq_for_peak(peak_idx);

% --- 4. 创建图窗，tiledlayout 上下排列 ---
fig = figure('Name', def.Scope, 'Visible', opts.Visible, 'Color', 'w');
layout = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact');
title(layout, sprintf('%s (%s)', def.Title, def.VariableName), 'Interpreter', 'none');

% --- 4a. 上图：时域波形 ---
nexttile(layout);
time_mask = time_s <= time_s(1) + opts.TimeSpanNs * 1e-9;
if ~any(time_mask)
    % 如果信号总时长不足 TimeSpanNs，退回到至少显示前 2000 点
    time_mask = 1:min(numel(time_s), 2000);
end
plot(time_s(time_mask) * 1e9, real(value(time_mask)), 'LineWidth', 0.8);
grid on;
xlabel('Time (ns)');
ylabel('Amplitude');
title(sprintf('Time view, first %.3g ns', opts.TimeSpanNs));

% --- 4b. 下图：频谱 ---
nexttile(layout);
plot(freq_hz(freq_mask) * 1e-6, mag_db(freq_mask), 'LineWidth', 0.8);
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dBFS-like)');            % dB Full Scale-like，相对于峰值的 dB
title(sprintf('Spectrum view, stride = %d, fs = %.3f GHz', stride, fs_hz / 1e9));

% 在频谱图上叠加预期频带高亮区域
draw_expected_band(def.ExpectedBandHz);

if any(freq_mask)
    xlim([0 opts.MaxFrequencyMHz]);
end

% --- 5. 保存图像 ---
figure_file = '';
if opts.SaveFigures
    figure_file = fullfile(opts.OutputDir, ...
        ['ex18_' clean_name(def.Scope) '_' opts.Timestamp '_time_spectrum.png']);
    try
        exportgraphics(fig, figure_file, 'Resolution', 160);
    catch
        saveas(fig, figure_file);           % 旧版 MATLAB 回退
    end
end

% --- 6. 构建信号摘要 ---
summary = struct();
summary.Scope               = def.Scope;             % 观测点名称
summary.VariableName        = def.VariableName;      % base 变量名
summary.SampleCount         = numel(value);           % 原始信号样本数
summary.SpectrumSampleCount = numel(spec_value);      % 降采样后样本数
summary.SpectrumStride      = stride;                 % 降采样步长
summary.SampleRateHz        = fs_hz * stride;         % 等效输入采样率
summary.SpectrumSampleRateHz = fs_hz;                 % 频谱实际使用的采样率
summary.RMS                 = sqrt(mean(abs(value).^2));  % 均方根值
summary.PeakFrequencyHz     = peak_hz;                % 频谱峰值频率
summary.ExpectedBandHz      = def.ExpectedBandHz;     % 预期频率范围
summary.FigureFile          = figure_file;            % 保存的图像路径

% 静默模式：关闭图窗（不弹出）
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

%% ========================================================================
% 频谱计算辅助
% ========================================================================
function [spec_t_s, spec_value, fs_hz, stride] = prepare_spectrum_signal(time_s, value, opts)
%PREPARE_SPECTRUM_SIGNAL 自适应降采样，确保 FFT 在合理大小内。
%
%   【降采样逻辑】
%     stride_for_length  — 按最大样本数约束算出的最小步长
%     stride_for_nyquist — 按 Nyquist 约束算出的最大步长
%                          （保证降采样后仍能观察到 MaxFrequencyMHz）
%     实际 stride 取两者的较大值（即两个约束都满足）
%
%   【输入】time_s, value — 原始信号
%   【输出】spec_t_s, spec_value — 降采样后的信号；fs_hz — 降采样后采样率；stride — 步长

sample_s = median(diff(time_s));               % 平均采样间隔 (s)
fs_hz    = 1 / sample_s;                        % 原始采样率 (Hz)

max_freq_hz = opts.MaxFrequencyMHz * 1e6;

% stride 取二者较大值 → stride越大降采样越激进，频谱点数越少
stride_for_length  = max(1, ceil(numel(value) / opts.MaxSamples));
stride_for_nyquist = max(1, floor(fs_hz / (2.5 * max_freq_hz)));
stride = max(stride_for_length, stride_for_nyquist);

% 每隔 stride 个点取一个样本
spec_t_s   = time_s(1:stride:end);
spec_value = value(1:stride:end);
fs_hz      = fs_hz / stride;                    % 等效采样率下降 stride 倍

% 仍超出 FFT 限制时截断
if numel(spec_value) > opts.MaxFftSamples
    spec_t_s   = spec_t_s(1:opts.MaxFftSamples);
    spec_value = spec_value(1:opts.MaxFftSamples);
end
end

function [freq_hz, mag_db] = compute_single_sided_spectrum(value, fs_hz, opts) %#ok<INUSD>
%COMPUTE_SINGLE_SIDED_SPECTRUM 计算实信号的 Hann 窗单边幅度谱。
%
%   【步骤】
%     1. 取实部，去均值（去除 DC 偏置）
%     2. 加 Hann 窗（抑制频谱泄漏，旁瓣压低到约 -32dB）
%     3. NFFT = 2^nextpow2(n)，补零到 2 的次幂以提高频域分辨率
%     4. 取单边谱 [0, fs/2]，乘以 2 补偿只取一半的幅度损失
%     5. 转换为 dB（相对谱峰最大值）
%
%   【输出】
%     freq_hz — 频率轴 (Hz)，从 0 到 Nyquist
%     mag_db  — 幅度 (dB)，相对于谱线最大值归一化

value = real(value(:));
value = value - mean(value);                   % 去 DC，避免零频尖峰
n = numel(value);

if n < 2
    freq_hz = 0;
    mag_db  = -300;
    return;
end

% Hann 窗：w[n] = 0.5 - 0.5*cos(2*pi*n/(N-1))
window = 0.5 - 0.5 * cos(2 * pi * (0:n - 1).' / max(n - 1, 1));
value  = value .* window;

% FFT + 补零到 2 的次幂
nfft = 2^nextpow2(min(n, opts.MaxFftSamples));
spec = fft(value, nfft);

% 取单边：[0, fs/2]，对应索引 1 到 floor(nfft/2)+1
keep = 1:floor(nfft / 2) + 1;
mag = abs(spec(keep)) * 2 / max(sum(window), eps);   % ×2 补偿单边幅度
freq_hz = (keep(:) - 1) * fs_hz / nfft;
mag_db  = 20 * log10(max(mag(:), eps));              % dB 相对峰值
end

%% ========================================================================
% 频谱图叠加：预期频带高亮
% ========================================================================
function draw_expected_band(band_hz)
%DRAW_EXPECTED_BAND 在频谱图上用半透明蓝色填充预期频率范围。
%
%   【用途】快速目视判断实际信号频谱是否落在设计频带内。
%   【原理】在背景层画一个 patch，然后用 circshift 把它移到数据线下面，
%           避免遮挡频谱曲线。

if numel(band_hz) ~= 2 || any(~isfinite(band_hz)) || band_hz(2) <= band_hz(1)
    return;    % 无效频带不绘制
end

yl = ylim;
patch([band_hz(1) band_hz(2) band_hz(2) band_hz(1)] * 1e-6, ...
    [yl(1) yl(1) yl(2) yl(2)], [0.85 0.92 1.0], ...
    'FaceAlpha', 0.25, 'EdgeColor', 'none');

% patch 默认画在最上层会遮挡频谱曲线，将其移到最底层
children = get(gca, 'Children');
set(gca, 'Children', circshift(children, -1));
ylim(yl);
end

%% ========================================================================
% 辅助函数
% ========================================================================
function name = clean_name(value)
%CLEAN_NAME 将字符串转换为文件名安全的格式。
%   示例: 'Scope_RX_IQ_Baseband' → 'scope_rx_iq_baseband'

name = lower(regexprep(value, '[^A-Za-z0-9]+', '_'));
name = regexprep(name, '^_+|_+$', '');       % 去掉首尾多余下划线
end

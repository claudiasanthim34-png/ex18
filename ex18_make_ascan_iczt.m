function results = ex18_make_ascan_iczt(varargin)
% 时窗修改---DelayStopNs
% 背景扣除---BackgroundMode

%EX18_MAKE_ASCAN_ICZT 使用 ICZT（Inverse Chirp Z-Transform）从 ex18 生成 A-scan。
%
%   ex18 A-scan 后处理的 ICZT 版本，整体处理链与
%   ex18_make_ascan.m 几乎完全一致，唯一区别在于：把"加窗后 IFFT"
%   这一步替换为"加窗后 ICZT"。ICZT 可以在任意时延区间以任意步长计算
%   A-scan，而不受 NFFT 必须覆盖整个不模糊时延范围的限制。
%

%   假设地下只有一个目标，回波相对发射信号延迟 tau 秒：
%       发射信号:  s_tx(t) = A * cos(2*pi*f*t)
%       接收信号:  s_rx(t) = B * cos(2*pi*f*(t - tau))
%                    = B * cos(2*pi*f*t - 2*pi*f*tau)
%   复数基带表示的发射和接收分别为:
%       S_tx(f) = A
%       S_rx(f) = B * exp(-j*2*pi*f*tau)
%   通道频响 H(f) = S_rx(f) / S_tx(f) = (B/A) * exp(-j*2*pi*f*tau)
%
%   可见 H(f) 是频率 f 的复正弦，相位斜率 -2*pi*tau 正比于目标时延 tau。
%   把多个等间隔频率点上的 H(f) 做 IFFT 或 ICZT，就能在时延轴上得到一
%   个峰值，峰值位置就是 tau。
%
%   多目标/多路径时，H(f) 是多个复正弦的叠加。不同时延对应不同频率
%   （相位斜率），IFFT/ICZT 可将它们分开，形成多个峰值，这就是 A-scan。
%
%
%   ========== 矩阵乘法实现 ==========
%
%   本文采用直接矩阵乘法实现 ICZT，无需 Signal Processing Toolbox
%   的 czt() 函数：
%
%   设 n_grid = [0, 1, ..., N-1]'  (N x 1 列向量)
%       k_grid = [0, 1, ..., M-1]   (1 x M 行向量)
%
%   构造核矩阵:
%       kernel(n,m) = exp(j*2*pi*n*m*df*dt)    尺寸 N x M
%
%   则:
%       partial(1xM) = g(1xN) * kernel(NxM)
%       ascan(1xM) = partial .* exp(j*2*pi*f0*t_m)
%
%   其中 g_n = H_n * w_n * exp(j*2*pi*n*df*t_start)，
%   除以 N 归一化后得到最终 A-scan。
%
%   ========== 处理链总览 ==========
%       1. 读取或运行单位置 Simulink 仿真。
%       2. 同步解调: 在每个 SFCW PRI 的稳定区间内做
%          tone_k = 2 * mean( y(t) * exp(-j2*pi*f_k*t) )
%          得到该频点的复幅度。
%       3. 发射和接收分别解调，相除得到频域通道响应:
%          H(f_k) = RX_tone(f_k) / SRC_tone(f_k)
%       4. 背景扣除: 用解析土壤模型生成不含目标的"背景频响"，
%          通过最小二乘匹配幅度/相位后，从 H(f) 中减去。
%       5. 前端延迟补偿 + 加窗:
%          response_corrected = H * exp(+j2*pi*f*tau0)
%          window = Kaiser (beta=6, 默认) / Hann / Rectangular
%       6. ICZT 矩阵乘法: 在指定时延区间 [t_start, t_stop] 内以
%          dt 步长计算 A-scan（参考袁林硕士论文式(1)）。
%       7. 目标检测: 在理论目标时延附近 ±TargetWindowNs/2 窗口内
%          找最大峰，验证实际峰位是否在容差范围内。
%
%   ========== 使用示例 ==========
%
%   % 从现有仿真日志生成 ICZT A-scan
%   ex18_make_ascan_iczt
%
%   % 自动围绕目标时延缩放
%   ex18_make_ascan_iczt('AutoZoom', true, 'NumDelayPoints', 8192)
%
%   % 指定延迟范围和步长
%   ex18_make_ascan_iczt('DelayStartNs', 5, 'DelayStopNs', 30, 'DelayStepNs', 0.05)
%
%   % 仿真 + ICZT A-scan
%   ex18_make_ascan_iczt('RunSimulation', true, 'SampleRate', 1e9)
%
%   results = ex18_make_ascan_iczt(...) 会返回包含所有中间结果的
%   结构体，方便用户后续做自定义分析或绘制。

% ===== 0. 初始化路径与工作区 =====
% 获取当前脚本所在目录并加入 MATLAB 路径，确保本目录下的
% filterlib、dialogs 子目录中的函数可被调用。
work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);

% 解析用户传入的可选参数。opts 是本次运行的配置集合。
% 时窗等参数的手动默认值在 parse_iczt_opts() 函数开头，直接打开修改即可。
opts = parse_iczt_opts(varargin{:});

% 为本次运行生成唯一时间戳，保存结果时用于文件名后缀。
opts.Timestamp = datestr(now, 'yyyymmdd_HHMMSS');

% ===== 1. (可选) 临时运行 Simulink 仿真 =====
% 若 RunSimulation=true，则临时改写模型的 InitFcn，运行后恢复，
% 避免对 .slx 文件产生永久修改。这样不需要预先手动运行模型。
if opts.RunSimulation
    run_single_position_simulation_iczt(opts);
end

% 确保 base workspace 中存在 cfg、sfw_meta、sfw_src_ts 等基础变量。
% 若用户从未调用过 setup_ex18_sfw，这里会自动补一次。
ensure_workspace_ready_iczt();
[cfg, meta] = read_context_iczt();

% ===== 2. 获取频域响应 H(f) =====
% 优先从仿真日志中估计；无日志时退回到 gpr_soil_model 的解析频响。
% frequency_hz 是实际参与 ICZT 的频率轴（列向量）。
% response 是复数频域响应。
% source_label 标记数据来源，会写入 results 并打印出来。
[frequency_hz, response, source_label] = get_frequency_response_iczt(cfg, meta, opts);
raw_response = response;  % 备份原始响应，便于在 results 中保留

% ===== 3. 背景扣除 =====
% 扣除直耦、地表反射和弱杂波，让目标回波更清楚。
% 默认 BackgroundMode='model'，使用 gpr_soil_model 中的解析背景频响。
[response, background] = apply_background_processing_iczt(frequency_hz, response, opts);

% ===== 4. ICZT 成像 =====
% 把频域响应变换到指定时延窗口内的 A-scan。
% 输出 results 中包含频率轴、时延轴、复数 A-scan、幅度、背景信息等。
results = build_ascan_iczt(frequency_hz, response, cfg, opts, source_label);
results.RawResponse = raw_response;       % 保存未做背景扣除的原始响应
results.Background = background;          % 保存背景扣除的状态

% ===== 5. 目标验证 =====
% 在理论目标时延附近窗口内找最大峰，与 cfg.gpr.target_delay_s 比较，
% 计算误差并判断 PASS/CHECK。
results = verify_target_iczt(results, cfg, opts);

% ===== 6. 绘图 =====
% 绘制 A-scan 曲线，标注理论时延位置和实测峰位。
results = plot_ascan_results_iczt(results, opts);

% ===== 7. 保存结果 =====
% 将 results 结构体保存到 .mat 文件，方便后续用 load() 复现分析。
if opts.SaveResults
    if exist(opts.OutputDir, 'dir') ~= 7
        mkdir(opts.OutputDir);
    end
    results.MatFile = fullfile(opts.OutputDir, ['ex18_ascan_iczt_' opts.Timestamp '.mat']);
    save(results.MatFile, 'results');
end

% ===== 8. 命令行总结 =====
% 打印本次运行的关键信息：方法、时延范围、目标检测结果等。
print_summary_iczt(results);
end

% =========================================================================
% 参数解析
% =========================================================================

function opts = parse_iczt_opts(varargin)
%PARSE_ICZT_OPTS 解析本脚本支持的可选参数。
%
%   使用 inputParser 实现类名-值对的参数解析。每个参数都附带类型校验
%   函数，避免运行时因为输入错误导致难以诊断的失败。
%
%   可选参数分类：
%     仿真控制: RunSimulation, StepCount, SampleRate
%     数据源:   InputSignal
%     成像:     Window, KaiserBeta, BackgroundMode
%     同步解调: ToneUseFraction, ToneEndGuardFraction
%     前端补偿: FrontendDelayCorrectionS
%     时延窗口: AutoZoom, DelayStartNs, DelayStopNs, DelayStepNs, NumDelayPoints
%     目标验证: TargetWindowNs
%     输出:     MaxPlotDelayNs, SaveResults, Visible, OutputDir

% ===== 手动配置区 —— 直接修改下面的数值即可改变默认值 =====
% 时窗起点/终点（AutoZoom=false 时生效），单位 ns。
cfg_auto_DelayStartNs    = 0;
cfg_auto_DelayStopNs     = 100;
% 自动时窗：true 时忽略上面的起点/终点，围绕目标自动展开。
cfg_auto_AutoZoom        = false;
% 延迟点数（分辨率控制），越大时间采样越密。
cfg_auto_NumDelayPoints  = 501;
% 显示横轴最大延迟，单位 ns。只影响显示，不影响计算。
cfg_auto_MaxPlotDelayNs  = 80;

parser = inputParser;

% --- 仿真控制参数 ---
% RunSimulation=true 时，先调用 sim('ex18_sfw_top') 再做 A-scan。
% false 时，只使用当前 base workspace 中已有的日志或模型频响。
parser.addParameter('RunSimulation', false, @(x) islogical(x) || isnumeric(x));

% StepCount 控制仿真时实际生成多少个 SFCW 频点。
% NaN 表示不覆盖 setup_ex18_sfw 的默认值，即完整 501 点。
parser.addParameter('StepCount', NaN, @(x) isnumeric(x) && isscalar(x));

% SampleRate 控制仿真采样率覆盖值。[] 表示使用 setup_ex18_sfw 默认。
parser.addParameter('SampleRate', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x) && x > 0));

% --- 数据源 ---
% InputSignal 是用于提取 A-scan 的接收端日志变量名。
% 默认 'rx_antenna_log' 对应接收天线原始输出。
parser.addParameter('InputSignal', 'rx_antenna_log', @(x) ischar(x) || isstring(x));

% --- 成像参数 ---
% Window 控制频域加窗类型。默认 'kaiser' (beta=6) 可在旁瓣抑制和
% 主瓣宽度之间取得平衡，优于 Hann 窗。
parser.addParameter('Window', 'kaiser', @(x) ischar(x) || isstring(x));

% KaiserBeta 控制 Kaiser 窗的旁瓣衰减。beta=6 时旁瓣约 -65 dB，
% 能有效压制地表直耦波旁瓣，防止淹没深层目标回波。
parser.addParameter('KaiserBeta', 6, @(x) isnumeric(x) && isscalar(x) && x > 0);

% BackgroundMode='model' 时扣除模型背景；'none' 时直接对原始响应 ICZT。
parser.addParameter('BackgroundMode', 'model', @(x) ischar(x) || isstring(x));

% --- 同步解调参数 ---
% 每个频点的 PRI 内，滤波器有瞬态过渡过程。
% ToneUseFraction: 使用每个脉冲后段的比例。
parser.addParameter('ToneUseFraction', 0.45, @(x) isnumeric(x) && isscalar(x) && x > 0 && x <= 1);

% 避开每个 PRI 最末尾一点点样本，减少频点切换边界对解调的污染。
parser.addParameter('ToneEndGuardFraction', 0.05, @(x) isnumeric(x) && isscalar(x) && x >= 0 && x < 1);

% --- 前端延迟补偿 ---
% 前端模型中包含约 3.8 ns 的等效群时延。补偿后 A-scan 横轴更
% 接近真实传播路径延迟。
parser.addParameter('FrontendDelayCorrectionS', 3.8e-9, @(x) isnumeric(x) && isscalar(x) && x >= 0);

% --- 时延窗口控制 ---
% AutoZoom: 自动围绕理论目标延迟设置延迟窗口。
% 若 AutoZoom=true，则忽略用户指定的 DelayStartNs/DelayStopNs。
parser.addParameter('AutoZoom', cfg_auto_AutoZoom, @(x) islogical(x) || isnumeric(x));

% 时延窗口起止，单位 ns。仅 AutoZoom=false 时生效。
parser.addParameter('DelayStartNs', cfg_auto_DelayStartNs, @(x) isnumeric(x) && isscalar(x) && x >= 0);
parser.addParameter('DelayStopNs', cfg_auto_DelayStopNs, @(x) isnumeric(x) && isscalar(x) && x > 0);

% 延迟步长，单位 ns。若为空则按 NumDelayPoints 自动计算。
parser.addParameter('DelayStepNs', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x) && x > 0));

% 输出延迟点数。若 DelayStepNs 为空，则用它反算步长。
% 默认 501 与频点数一致，保证时延分辨率与频域分辨率匹配。
parser.addParameter('NumDelayPoints', cfg_auto_NumDelayPoints, @(x) isnumeric(x) && isscalar(x) && x >= 8);

% --- 目标验证 ---
% 目标验证时，只在理论目标延迟附近这个窗口内找峰，避免直耦或旁瓣被误判。
parser.addParameter('TargetWindowNs', 16, @(x) isnumeric(x) && isscalar(x) && x > 0);

% 图中 A-scan 横轴最大显示延迟。只影响显示，不影响计算和保存结果。
% 默认 700 ns 覆盖 0-700 ns 全窗口。
parser.addParameter('MaxPlotDelayNs', cfg_auto_MaxPlotDelayNs, @(x) isnumeric(x) && isscalar(x) && x > 0);

% --- 输出控制 ---
% 是否保存 ex18_ascan_iczt_*.png 和 .mat 文件。
parser.addParameter('SaveResults', true, @(x) islogical(x) || isnumeric(x));

% Visible='off' 适合批处理；Visible='on' 会弹出图窗。
parser.addParameter('Visible', 'on', @(x) ischar(x) || isstring(x));

% 输出目录，默认放在 ex18/output。
parser.addParameter('OutputDir', fullfile(fileparts(mfilename('fullpath')), 'output'), ...
    @(x) ischar(x) || isstring(x));

parser.parse(varargin{:});
opts = parser.Results;

% 后处理时统一数据类型，避免后续字符串/逻辑/整数处理出现版本差异。
opts.RunSimulation = logical(opts.RunSimulation);
opts.AutoZoom = logical(opts.AutoZoom);
opts.StepCount = round(opts.StepCount);
opts.InputSignal = char(opts.InputSignal);
opts.Window = lower(char(opts.Window));
opts.BackgroundMode = lower(char(opts.BackgroundMode));
opts.SaveResults = logical(opts.SaveResults);
opts.Visible = char(opts.Visible);
opts.OutputDir = char(opts.OutputDir);
end

% =========================================================================
% 仿真驱动：临时运行 ex18 顶层模型
% =========================================================================

function run_single_position_simulation_iczt(opts)
%RUN_SINGLE_POSITION_SIMULATION_ICZT 临时运行当前 ex18 顶层模型。
%
%   这里不直接改 .slx 文件，而是：
%       1. 记住原来的 InitFcn 和 Dirty 状态。
%       2. 临时把 InitFcn 改成带 StepCount/SampleRate 的 setup_ex18_sfw 调用。
%       3. sim 完成后把日志复制回 base workspace。
%       4. 函数退出时通过 onCleanup 自动恢复原 InitFcn 和 Dirty 状态。
%
%   这样后续 A-scan 步骤与"手动 Run 一次模型再调用本脚本"得到的结果一致，
%   但又不会污染用户保存的 .slx 文件。

model = 'ex18_sfw_top';
model_file = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);
load_system(model_file);

% 保护用户模型状态。即使仿真中出错，onCleanup 也会尽量恢复。
old_init = get_param(model, 'InitFcn');
old_dirty = get_param(model, 'Dirty');
cleanup = onCleanup(@() restore_model_init_iczt(model, old_init, old_dirty));

% 只把用户显式传入的覆盖项写进临时 InitFcn。
% 例如 SampleRate=[] 时，不覆盖 setup_ex18_sfw.m 的默认采样率。
setup_args = {};
if ~isnan(opts.StepCount)
    setup_args(end + 1:end + 2) = {'StepCount', opts.StepCount};
end
if ~isempty(opts.SampleRate)
    setup_args(end + 1:end + 2) = {'SampleRate', opts.SampleRate};
end
init_cmd = setup_call_text_iczt(setup_args);

set_param(model, 'InitFcn', init_cmd);

% ReturnWorkspaceOutputs='on' 让 To Workspace 日志进入 sim_out。
% 后面再复制到 base workspace，保持和手动 Run 后的使用体验一致。
sim_out = sim(model, 'ReturnWorkspaceOutputs', 'on');
copy_sim_outputs_to_base_iczt(sim_out);
end

function text = setup_call_text_iczt(args)
%SETUP_CALL_TEXT_ICZT 把 {'Name', value, ...} 转成可写入 InitFcn 的 MATLAB 文本。
%
%   这样模型仿真启动时会自动执行对应 setup，确保 sfw_src_ts、滤波器
%   系数、GPR FIR 等 workspace 变量与本次运行参数一致。
if isempty(args)
    text = 'setup_ex18_sfw;';
    return;
end
parts = cell(1, numel(args));
for k = 1:2:numel(args)
    parts{k} = sprintf('''%s''', args{k});
    parts{k + 1} = sprintf('%.17g', args{k + 1});
end
text = ['setup_ex18_sfw(' strjoin(parts, ', ') ');'];
end

function copy_sim_outputs_to_base_iczt(sim_out)
%COPY_SIM_OUTPUTS_TO_BASE_ICZT 把 Simulink 日志变量复制到 base workspace。
%
%   ex18_make_ascan_iczt 后续会从 base workspace 读取 rx_antenna_log 和
%   sfw_src_ts。这里复制的几个变量都是模型中的 To Workspace 日志。
%
%   各日志含义:
%     rf_out_log         : 发射天线输出（即 RF_Out 端口）
%     tap_up_log         : 耦合支路上变频后（Tap_Up_BPF 输出）
%     rx_down_if_log     : 下变频 IF 输出（RX_Down_IF_BPF 输出）
%     rx_iq_baseband_log : I/Q 解调后的复数基带
%     rx_antenna_log     : 接收天线原始输出（默认作为 H(f) 估计源）
names = {'rf_out_log', 'tap_up_log', 'rx_down_if_log', 'rx_iq_baseband_log', 'rx_antenna_log'};
for k = 1:numel(names)
    try
        value = sim_out.get(names{k});
    catch
        % 如果某个日志变量不存在（取决于当前模型是否启用对应输出），
        % 静默跳过，不影响其他变量。
        continue;
    end
    assignin('base', names{k}, value);
end
end

function restore_model_init_iczt(model, old_init, old_dirty)
%RESTORE_MODEL_INIT_ICZT 恢复模型 InitFcn 和 Dirty 标志。
%   这样本脚本临时运行仿真不会改变用户手动保存的模型排版或参数。
if bdIsLoaded(model)
    set_param(model, 'InitFcn', old_init);
    set_param(model, 'Dirty', old_dirty);
end
end

% =========================================================================
% 工作区准备与基础配置读取
% =========================================================================

function ensure_workspace_ready_iczt()
%ENSURE_WORKSPACE_READY_ICZT 确保基础配置变量存在。
%
%   cfg 保存 ex18 当前配置，sfw_meta 保存 SFCW 时间轴、频率轴、PRI 等
%   派生信息。没有这些变量就无法按频点分段解调。
if ~base_has_var_iczt('cfg') || ~base_has_var_iczt('sfw_meta')
    setup_ex18_sfw();
end
end

function [cfg, meta] = read_context_iczt()
%READ_CONTEXT_ICZT 从 base workspace 读取配置和 SFCW 元数据。
%   使用 evalin 是为了和 Simulink/From Workspace 的变量来源保持一致。
cfg = evalin('base', 'cfg');
meta = evalin('base', 'sfw_meta');
end

% =========================================================================
% 频域响应获取（仿真日志 / 模型参考）
% =========================================================================

function [frequency_hz, response, source_label] = get_frequency_response_iczt(cfg, meta, opts)
%GET_FREQUENCY_RESPONSE_ICZT 得到用于 ICZT 的复频域响应 H(f)。
%
%   优先级如下：
%       1. 如果 base workspace 中有仿真日志 opts.InputSignal 和 sfw_src_ts，
%          就从时域日志中按频点同步解调得到 H(f)。
%       2. 如果没有日志，但有 gpr_soil_model，就直接使用模型解析频响。
%   第 1 种更接近当前 Simulink 时域链路，第 2 种适合快速检查成像逻辑。

% 取出 SFCW 实际频点（来自 meta.freq_hz，是 setup_ex18_sfw 计算的）。
frequency_hz = meta.freq_hz(:);

% 路径 1: 仿真日志。
if base_has_var_iczt(opts.InputSignal) && base_has_var_iczt('sfw_src_ts')
    raw_rx = evalin('base', opts.InputSignal);
    raw_src = evalin('base', 'sfw_src_ts');
    response = response_from_rx_log_iczt(raw_rx, raw_src, frequency_hz, meta, opts);
    source_label = sprintf('simulation log: %s / sfw_src_ts', opts.InputSignal);
    return;
end

% 路径 2: 模型参考（gpr_soil_model）。
if base_has_var_iczt('gpr_soil_model')
    model = evalin('base', 'gpr_soil_model');
    response = response_from_soil_model_iczt(model, frequency_hz);
    source_label = 'model response: gpr_soil_model.sfcw_response';
    return;
end

% 两条路径都不可用，提示用户先运行仿真或 setup_ex18_sfw。
error('ex18_make_ascan_iczt:NoResponseSource', ...
    ['No usable simulation log or gpr_soil_model was found. Run sim(''ex18_sfw_top'') first, ' ...
    'or call ex18_make_ascan_iczt(''RunSimulation'', true).']);
end

function response = response_from_rx_log_iczt(raw_rx, raw_src, frequency_hz, meta, opts)
%RESPONSE_FROM_RX_LOG_ICZT 从时域仿真记录中估计 SFCW 复频响。
%
%   ===== 同步解调原理（SFCW 复幅度提取）=====
%
%   SFCW 的每个 PRI（脉冲重复周期）内只发射一个频点 f_k。
%   对该 PRI 内的接收时域波形 y_k(t)，用复指数 exp(-j2*pi*f_k*t) 相乘后取平均：
%       tone_k = 2 * mean_{t in PRI}[ y_k(t) * exp(-j2*pi*f_k*t) ]
%
%   为什么要乘 exp(-j2*pi*f_k*t)？
%       发射信号为 cos(2*pi*f_k*t)，接收信号经过通道后变为：
%           y_k(t) = A_k * cos(2*pi*f_k*t + phi_k)
%                  = (A_k/2) * [exp(j(2*pi*f_k*t+phi_k)) + exp(-j(2*pi*f_k*t+phi_k))]
%       乘 exp(-j2*pi*f_k*t) 后：
%           y_k(t) * exp(-j2*pi*f_k*t) = (A_k/2)*exp(j*phi_k) + (A_k/2)*exp(-j(4*pi*f_k*t+phi_k))
%       第一项是 DC 分量（幅度 A_k/2，相位 phi_k），
%       第二项是 2*f_k 高频分量。取时间平均后高频分量趋近于 0：
%           mean[ y_k(t) * exp(-j2*pi*f_k*t) ] ≈ (A_k/2) * exp(j*phi_k)
%       乘以 2 恢复完整幅度: tone_k = A_k * exp(j*phi_k)
%       这就是该频点的复幅度——其实部和虚部分别包含了余弦的同相和正交分量。
%
%   对接收端和发射端分别做一次解调，取比值：
%       H(f_k) = RX_complex(f_k) / SRC_complex(f_k)
%   这样可以抵消信号源自身幅度/相位不平坦，只保留通道+前端响应。

% 提取时域波形（统一处理 timeseries / Structure With Time 格式）。
[rx_time_s, rx_value] = extract_signal_iczt(raw_rx, 'rx log');
[src_time_s, src_value] = extract_signal_iczt(raw_src, 'src log');

% 按 SFCW 频点逐个做同步解调。
rx_tones = extract_step_tones_iczt(rx_time_s, rx_value, frequency_hz, meta, opts);
src_tones = extract_step_tones_iczt(src_time_s, src_value, frequency_hz, meta, opts);

% 弱源频点（信号太弱、采样率不足或 PRI 太短）会让除法放大噪声。
% 因此过滤掉接近 0 的源频点，再用 fillmissing_complex_iczt 插值补齐。
good = abs(src_tones) > max(abs(src_tones)) * 1e-6;
if nnz(good) < numel(frequency_hz)
    warning('ex18_make_ascan_iczt:WeakReference', ...
        'Only %d/%d source tone estimates were above threshold.', ...
        nnz(good), numel(frequency_hz));
end

response = nan(size(rx_tones));
response(good) = rx_tones(good) ./ src_tones(good);
% 仿真日志偶尔可能因为过短或边界问题缺少个别频点，这里用复数插值补齐。
% 线性插值对复数的实部和虚部分别等价，保留了幅相连续性。
response = fillmissing_complex_iczt(response);
end

function response = response_from_soil_model_iczt(model, frequency_hz)
%RESPONSE_FROM_SOIL_MODEL_ICZT 从 gpr_soil_model 中取出 SFCW 频点响应。
%   优先使用 sfcw_response，因为它是在真实 SFCW 频率点上直接计算的。
%   如果旧版本模型没有 sfcw_response，则退回到 FIR 频率网格插值。
if isfield(model, 'sfcw_response') && isfield(model, 'sfcw_frequency_hz')
    response = interp1(model.sfcw_frequency_hz(:), model.sfcw_response(:), ...
        frequency_hz(:), 'linear', 'extrap');
elseif isfield(model, 'frequency_hz') && isfield(model, 'response')
    response = interp1(model.frequency_hz(:), model.response(:), ...
        frequency_hz(:), 'linear', 'extrap');
else
    error('ex18_make_ascan_iczt:BadSoilModel', ...
        'gpr_soil_model does not contain a usable frequency response.');
end
end

% =========================================================================
% 同步解调核心
% =========================================================================

function tones = extract_step_tones_iczt(time_s, value, frequency_hz, meta, opts)
%EXTRACT_STEP_TONES_ICZT 对每个 SFCW 频点做同步解调，提取复幅度。
%
%   ===== 算法推导 =====
%   输入 time_s/value 是一整段时域波形，包含 N 个频点，每个频点占一个 PRI。
%   meta 中记录了每个 PRI 的起止时间（pulse_start_s / pulse_stop_s）。
%
%   第 k 个频点 f_k 的接收信号（在 PRI 内）近似为：
%       y_k(t) ≈ A_k * cos(2*pi*f_k*t + phi_k)
%   其中 A_k 为幅度，phi_k 为相位（包含了通道衰减和传播延迟的信息）。
%
%   同步解调步骤：
%   1. 乘以复指数:  z(t) = y_k(t) * exp(-j*2*pi*f_k*t)
%      利用 Euler 公式 cos(x) = (exp(jx)+exp(-jx))/2，展开得：
%          z(t) = (A_k/2)*exp(j*phi_k) + (A_k/2)*exp(-j(4*pi*f_k*t+phi_k))
%               ^^^^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
%                      DC 分量                        2*f_k 高频分量
%
%   2. 时间平均:    tone_k = 2 * mean[z(t)]
%      高频分量在足够长的平均窗口内趋近于 0；
%      DC 分量 = (A_k/2)*exp(j*phi_k)，乘以 2 恢复 A_k*exp(j*phi_k)。
%
%   tone_k 的模 |tone_k| = A_k 就是该频点接收信号的幅度，
%   angle(tone_k) = phi_k 就是该频点的相位（包含了回波时延信息）。
%
%   ===== 稳定区间选取 =====
%   每个 PRI 的前段包含滤波器瞬态响应（BPF、LPF 的群时延和冲击响应尾部），
%   幅度和相位尚未稳定。因此只取每个 PRI 的后段 ToneUseFraction 比例区间
%   做平均，并留出 ToneEndGuardFraction 避免频点切换边界的污染。
%
%   例如 ToneUseFraction=0.45, ToneEndGuardFraction=0.05 表示：
%   取每个 PRI 的 50%~95% 区间（后段 45%，末尾留 5% 保护带）。
tones = complex(nan(numel(frequency_hz), 1));
for k = 1:numel(frequency_hz)
    % 每个频点占用一个 PRI。pulse_start_s/pulse_stop_s 来自 make_sfw_burst。
    step_start_s = meta.pulse_start_s(k);
    step_stop_s = meta.pulse_stop_s(k);
    pulse_s = step_stop_s - step_start_s;

    % 只取每个频点后段稳定区间。前段可能包含滤波器瞬态；最后一点附近
    % 可能接近下一频点切换边界，因此也留出 ToneEndGuardFraction。
    win_stop_s = step_stop_s - opts.ToneEndGuardFraction * pulse_s;
    win_start_s = win_stop_s - opts.ToneUseFraction * pulse_s;
    win_start_s = max(win_start_s, step_start_s);

    idx = time_s >= win_start_s & time_s < win_stop_s;
    if nnz(idx) < 8
        % 如果采样率太低或 PRI 太短导致稳定窗口样本过少，则退回使用整个脉冲。
        idx = time_s >= step_start_s & time_s < step_stop_s;
    end
    if nnz(idx) < 2
        % 样本仍不足时保留 NaN，后续 fillmissing_complex_iczt 会尝试插值补齐。
        continue;
    end

    t = time_s(idx);
    y = value(idx);
    % 同步解调: 乘 exp(-j2*pi*f_k*t) 把信号搬移到 DC，再取平均。
    % 系数 2 用于补偿实数余弦信号只有一半功率在正频率分量。
    tones(k) = 2 * mean(y(:) .* exp(-1i * 2 * pi * frequency_hz(k) .* t(:)));
end
end

function value = fillmissing_complex_iczt(value)
%FILLMISSING_COMPLEX_ICZT 对缺失复频点做线性插值。
%
%   ICZT 要求频域向量不能有 NaN/Inf。这里分别等价地对复数
%   序列做线性插值，保留幅相连续性。若有效点太少，则直接报错。
bad = ~isfinite(real(value)) | ~isfinite(imag(value));
if ~any(bad)
    return;
end

idx = (1:numel(value)).';
good = ~bad;
if nnz(good) < 2
    error('ex18_make_ascan_iczt:TooFewTones', 'Too few valid tone estimates for ICZT.');
end
value(bad) = interp1(idx(good), value(good), idx(bad), 'linear', 'extrap');
end

function [time_s, value] = extract_signal_iczt(raw, var_name)
%EXTRACT_SIGNAL_ICZT 统一读取 timeseries 和 To Workspace 结构体格式。
%
%   Simulink 中不同日志块可能输出 timeseries 或 Structure With Time。
%   本函数把它们统一整理成两个列向量：time_s 和 value。
if isa(raw, 'timeseries')
    time_s = raw.Time;
    value = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    time_s = raw.time;
    value = raw.signals.values;
else
    error('ex18_make_ascan_iczt:BadSignal', 'Unsupported signal format for %s.', var_name);
end

time_s = double(time_s(:));
value = squeeze(value);
if ~isvector(value)
    % 如果信号是多列或多通道，只取第 1 路。ex18 当前 A-scan 链路使用单通道。
    if size(value, 1) ~= numel(time_s) && size(value, 2) == numel(time_s)
        value = value.';
    end
    value = reshape(value, size(value, 1), []);
    value = value(:, 1);
end
value = double(value(:));

% 对齐时间轴与值长度。
n = min(numel(time_s), numel(value));
time_s = time_s(1:n);
value = value(1:n);

finite_idx = isfinite(time_s) & isfinite(value);
% 去掉非有限值，避免后续解调平均时污染复幅度估计。
time_s = time_s(finite_idx);
value = value(finite_idx);
end

% =========================================================================
% 背景扣除（与 IFFT 版本完全一致）
% =========================================================================

function [response, background] = apply_background_processing_iczt(frequency_hz, response, opts)
%APPLY_BACKGROUND_PROCESSING_ICZT 执行背景扣除处理。
%
%   ===== 为什么需要背景扣除？ =====
%   GPR 接收信号中，管道目标回波通常远弱于以下背景分量：
%       direct  : 发射天线到接收天线的直接耦合（电磁波不经地下传播，
%                 直接从 Tx 耦合到 Rx）。这是最强的背景分量。
%       surface : 地表反射（空气-土壤界面的 Fresnel 反射）。
%       clutter : 土壤中随机分布的小石块、树根等弱散射体回波。
%
%   如果不扣除这些背景，目标回波会被淹没，A-scan 上看不到管道峰。
%
%   ===== 扣除模型背景的原理 =====
%   利用解析土壤模型生成一组"无目标"的频域响应 H_background(f)，
%   它只包含 direct + surface + clutter 分量。
%
%   由于仿真数据经过 RF Blockset 链路，幅度/相位和解析模型不完全一致，
%   需要先估计一个复数比例 scale，使 scale*H_background(f) 的幅度和
%   相位匹配仿真数据的背景分量：
%       scale = argmin || H_measured(f) - c * H_background(f) ||^2
%             = (H_background' * H_measured) / (H_background' * H_background)
%   这是复数域的最小二乘问题（complex_scale_iczt 函数）。
%
%   然后扣除:  H_bgsub(f) = H_measured(f) - scale * H_background(f)
%   残差 H_bgsub(f) 中主要剩下目标响应（和被背景减法未完全消除的残差）。

background = struct();
background.Mode = opts.BackgroundMode;
background.Applied = false;
background.Scale = 1;
background.Response = zeros(size(response));

switch opts.BackgroundMode
    case 'none'
        % 不做背景扣除，直接对原始 H(f) 做 ICZT。
        % 这时 A-scan 最前面的强峰通常是直耦和地表反射，目标峰往往被遮盖。
        return;
    case 'model'
        if ~base_has_var_iczt('gpr_soil_model')
            warning('ex18_make_ascan_iczt:NoBackgroundModel', ...
                'BackgroundMode=model requested, but gpr_soil_model is missing. Using raw response.');
            return;
        end
        model = evalin('base', 'gpr_soil_model');
        if ~isfield(model, 'sfcw_parts') || ~isfield(model.sfcw_parts, 'background_response')
            warning('ex18_make_ascan_iczt:NoBackgroundParts', ...
                'gpr_soil_model has no component background response. Using raw response.');
            return;
        end

        % model_total    = 模型完整频响（直耦 + 地表 + 杂波 + 目标）
        % model_background = 模型背景频响（直耦 + 地表 + 杂波，不含目标）
        % scale 是复数最小二乘比例，匹配模型的幅度和相位到仿真数据。
        model_total = response_from_soil_model_iczt(model, frequency_hz);
        model_background = interp_model_part_iczt(model, 'background_response', frequency_hz);
        scale = complex_scale_iczt(model_total, response);
        % 背景扣除: H_bgsub = H_measured - scale*H_background_model
        response = response - scale .* model_background;

        background.Applied = true;
        background.Scale = scale;
        background.Response = scale .* model_background;
    otherwise
        error('ex18_make_ascan_iczt:BadBackgroundMode', ...
            'Unsupported BackgroundMode: %s. Use ''model'' or ''none''.', opts.BackgroundMode);
end
end

function part = interp_model_part_iczt(model, name, frequency_hz)
%INTERP_MODEL_PART_ICZT 取出 gpr_soil_model.sfcw_parts 中的指定分量并插值。
%   可用分量包括 background_response、target_response、direct_response 等。
if isfield(model, 'sfcw_frequency_hz') && isfield(model, 'sfcw_parts') && ...
        isfield(model.sfcw_parts, name)
    part = interp1(model.sfcw_frequency_hz(:), model.sfcw_parts.(name)(:), ...
        frequency_hz(:), 'linear', 'extrap');
else
    error('ex18_make_ascan_iczt:MissingModelPart', 'Missing model part: %s.', name);
end
end

function scale = complex_scale_iczt(reference, measured)
%COMPLEX_SCALE_ICZT 复数最小二乘比例估计: measured ≈ scale * reference。
%
%   ===== 数学推导 =====
%   问题: 找复数 c，使得 || measured - c * reference ||^2 最小。
%   目标函数: J(c) = sum_k |measured_k - c * reference_k|^2
%   J(c) 是 c 的二次型，最小值在导数零点:
%       dJ/dc* = reference'*(c*reference - measured) = 0
%       即 c * (reference'*reference) = reference'*measured
%       => c = (reference'*measured) / (reference'*reference)
%   其中 ' 表示共轭转置 Hermitian inner product。
%
%   ===== 物理意义 =====
%   在背景扣除中，reference 是模型背景频响 H_background(f)，
%   measured 是仿真得到的原始频响 H_measured(f)。
%   scale 是一个复数，其幅度 |scale| 匹配模型到仿真的增益差异
%   （RF Blockset 端口换算、天线增益等），其相位 angle(scale) 匹配
%   整体相位偏移（RF 链路群时延、本振相噪等）。
%
%   用 scale * H_background(f) 近似仿真中实际的背景分量，
%   再从 H_measured(f) 中减去，剩余的主要是目标回波。
reference = reference(:);
measured = measured(:);
den = reference' * reference;   % Hermitian 内积: ||reference||^2
if abs(den) < eps
    scale = 1;                  % 背景太弱，不做匹配
else
    scale = (reference' * measured) / den;  % 最小二乘解
end
end

% =========================================================================
% ICZT A-scan 构建（核心）
% =========================================================================

function results = build_ascan_iczt(frequency_hz, response, cfg, opts, source_label)
%BUILD_ASCAN_ICZT 使用 ICZT 将频域响应转换为时延域 A-scan。
%
%   这是本脚本最核心的函数。处理链：
%       1. 频响列化 + 派生参数（df, bandwidth, f_start）
%       2. 频域加窗（Hann / Rectangular）
%       3. 前端延迟补偿（消除 RF 链路固定群时延）
%       4. 构造 g_n = H_corrected(n) * exp(j*2*pi*n*df*t_start)
%       5. CZT 参数计算 W = exp(j*2*pi*df*dt)
%       6. 调用 czt() 计算 CZT
%       7. 后乘 K_m = exp(j*2*pi*f_start*t_m) 还原完整相位
%       8. 构造时延轴、深度轴、幅度（线性、dB）

% 频响列化（确保是列向量）。
frequency_hz = frequency_hz(:);
response = response(:);
f_start_hz = frequency_hz(1);
df_hz = mean(diff(frequency_hz));                % 频率步进 (Hz)
bandwidth_hz = frequency_hz(end) - frequency_hz(1);  % 总带宽 (Hz)

% 频域加窗（默认 Kaiser beta=6，旁瓣约 -65 dB）。
window = make_window_iczt(numel(response), opts);

% 前端延迟补偿。补偿 exp(+j2*pi*f*tau0)，抵消 RF 链路固定群时延。
delay_correction_s = opts.FrontendDelayCorrectionS;
response_corrected = response .* exp(1i * 2 * pi * frequency_hz * delay_correction_s);

% 确定时延轴参数：[t_start, t_stop], dt, num_points。
[delay_start_s, delay_stop_s, dt_s, num_delays] = resolve_delay_axis(opts, cfg, df_hz);

% ===== ICZT 矩阵乘法实现 =====
% A-scan 定义: ascan(t_m) = sum_{n=0}^{N-1} H_n * exp(j*2*pi*f_n*t_m)
% 其中 f_n = f_start + n*df,  t_m = t_start + m*dt.
%
% 参考袁林硕士论文式(1)，将求和展开为矩阵乘法:
%   ascan(t_m) = exp(j*2*pi*f_start*t_m) * sum_n H_n * exp(j*2*pi*n*df*t_m)
%
% 构造核矩阵 kernel(n,m) = exp(j*2*pi*n*m*df*dt)，尺寸 N x M。
% 设 g_n = H_n * w_n * exp(j*2*pi*n*df*t_start)，尺寸 1 x N。
% 则 partial = g * kernel = sum_n g_n * exp(j*2*pi*n*m*df*dt)，尺寸 1 x M。
%
% 最终: ascan(t_m) = partial(m) * exp(j*2*pi*f_start*t_m) / N
% 除以 N 将求和归一化为"每频点平均"，消除 t=0 附近的 DC 基座。

% Step 1: 构造 g_n = H_corrected(n) * window(n) * exp(j*2*pi*n*df*t_start)
n_grid = (0:numel(response)-1).';  % 频域索引列向量 N x 1
k_grid = 0:num_delays-1;           % 时域索引行向量 1 x M
g = (response_corrected .* window .* exp(1i * 2 * pi * n_grid * df_hz * delay_start_s)).';  % 1 x N

% Step 2: 构造核矩阵 kernel(n,m) = exp(j*2*pi*n*m*df*dt)，尺寸 N x M
kernel_matrix = exp(1i * 2 * pi * n_grid * k_grid * df_hz * dt_s);

% Step 3: 矩阵乘法 g (1 x N) * kernel (N x M) = partial (1 x M)
% partial(m) = sum_n g_n * exp(j*2*pi*n*m*df*dt)
ascan_partial = g * kernel_matrix;  % 1 x M

% Step 4: 时延轴生成与起始相位补偿
% ascan(t_m) = partial(m) * exp(j*2*pi*f_start*t_m)
delay_axis_s = delay_start_s + k_grid * dt_s;         % 1 x M
ascan_complex = ascan_partial .* exp(1i * 2 * pi * f_start_hz * delay_axis_s);  % 1 x M
ascan_complex = ascan_complex(:);                      % 转为 M x 1 列向量
delay_axis_s = delay_axis_s(:);                        % 转为 M x 1 列向量

% Step 5: 归一化 — 除以频点数 N，使输出幅度与 IFFT 约定一致
ascan_complex = ascan_complex / numel(frequency_hz);

% ===== 派生显示量 =====
% 时延轴: t = t_start + m*dt, m = 0, 1, ..., M-1
% 深度轴: depth = v_soil * tau / 2
%   除以 2 是因为 depth 是单程距离（电磁波走了来回 2*depth）。
% 幅度: |ascan|。dB 归一化到 0 dB，便于观察相对反射强度。
% 注意: 这是相对值，不代表绝对 RCS 或雷达方程中的功率。
depth_axis_m = cfg.gpr.soil_velocity_mps * delay_axis_s / 2;
amplitude = abs(ascan_complex);
amplitude_db = 20 * log10(amplitude / max(amplitude + eps) + eps);

% 打包返回结构体。
results = struct();
results.Method = 'ICZT';
results.Source = source_label;             % 数据来源（仿真日志/模型参考）
results.FrequencyHz = frequency_hz;        % SFCW 频率轴 (Hz)
results.Response = response;               % 背景扣除后的频响 H(f)
results.ResponseCorrected = response_corrected;  % 经延迟补偿的频响
results.Window = window;                   % 使用的窗函数
results.AScan = ascan_complex;             % ICZT 复数结果（时延域）
results.TimeAxisS = delay_axis_s;          % 时延轴 (s)
results.DepthAxisM = depth_axis_m;         % 等效深度轴 (m)
results.Amplitude = amplitude;             % 幅度（线性）
results.AmplitudeDb = amplitude_db;        % 幅度 (dB, 归一化)
results.DelayStartS = delay_start_s;       % 时延窗口起点 (s)
results.DelayStopS = delay_stop_s;         % 时延窗口终点 (s)
results.DelayStepS = dt_s;                 % 时延步长 (s)
results.NumDelayPoints = num_delays;       % 时延点数
results.DfHz = df_hz;                      % 频率步进
results.BandwidthHz = bandwidth_hz;        % 总带宽
results.FrontendDelayCorrectionS = delay_correction_s;
results.BackgroundMode = opts.BackgroundMode;
results.Expected = expected_delays_iczt(cfg);  % 理论时延（用于验证）
results.FigureFile = '';
results.MatFile = '';
end

function [delay_start_s, delay_stop_s, dt_s, num_delays] = resolve_delay_axis(opts, cfg, df_hz)
%RESOLVE_DELAY_AXIS 根据用户参数确定 ICZT 时延轴。
%
%   时延轴的设定优先级:
%     1. AutoZoom=true:
%          起点 = max(0, target_delay_s - 2*TargetWindowNs)
%          终点 = target_delay_s + 2*TargetWindowNs
%          步长 = DelayStepNs（若指定）或 (终点-起点)/(NumDelayPoints-1)
%     2. AutoZoom=false:
%          起点 = DelayStartNs
%          终点 = DelayStopNs
%          步长 = DelayStepNs（若指定）或 (终点-起点)/(NumDelayPoints-1)
%   最后做合法性检查。

% 总频率带宽 = df * (频点数 - 1)，在 AutoZoom 分支可能用不到。
freq_bandwidth_hz = df_hz * (numel(cfg.freq.hz) - 1);

if opts.AutoZoom
    % 围绕理论目标延迟自动设置窗口: [target - 2*TargetWindowNs, target + 2*TargetWindowNs]
    % 乘以 2 让窗口宽度是 TargetWindowNs 的 4 倍，留出前后余量便于观察旁瓣。
    target_s = cfg.gpr.target_delay_s;
    half_win_s = 2 * opts.TargetWindowNs * 1e-9;
    delay_start_s = max(0, target_s - half_win_s);
    delay_stop_s = target_s + half_win_s;

    % 步长: 若用户指定了 DelayStepNs 就用它，否则按 NumDelayPoints 计算。
    if ~isempty(opts.DelayStepNs)
        dt_s = opts.DelayStepNs * 1e-9;
        num_delays = ceil((delay_stop_s - delay_start_s) / dt_s) + 1;
    else
        % 在窗口内按 NumDelayPoints 均匀采样。
        num_delays = opts.NumDelayPoints;
        dt_s = (delay_stop_s - delay_start_s) / (num_delays - 1);
    end
else
    % 手动指定窗口。
    delay_start_s = opts.DelayStartNs * 1e-9;
    delay_stop_s = opts.DelayStopNs * 1e-9;

    if ~isempty(opts.DelayStepNs)
        dt_s = opts.DelayStepNs * 1e-9;
        num_delays = ceil((delay_stop_s - delay_start_s) / dt_s) + 1;
    else
        num_delays = opts.NumDelayPoints;
        dt_s = (delay_stop_s - delay_start_s) / (num_delays - 1);
    end
end

% 参数合法性检查。
if dt_s <= 0
    error('ex18_make_ascan_iczt:BadDelayStep', 'DelayStepNs must be positive.');
end
if num_delays < 4
    error('ex18_make_ascan_iczt:TooFewPoints', 'At least 4 delay points required.');
end
end


% =========================================================================
% 加窗函数
% =========================================================================

function window = make_window_iczt(n, opts)
%MAKE_WINDOW_ICZT 生成频域加窗向量。
%
%   Kaiser 窗 (beta=6): 旁瓣约 -65 dB，主瓣略宽但旁瓣极低。
%     适合压制地表直耦波旁瓣，防止淹没深层弱目标（如管道回波）。
%   Hann 窗: w(m) = 0.5 - 0.5*cos(2*pi*m/(N-1)), 旁瓣约 -31.5 dB
%   Rectangular 窗: w(m) = 1, 旁瓣约 -13 dB，不加窗。
switch lower(opts.Window)
    case 'kaiser'
        window = kaiser(n, opts.KaiserBeta);
    case {'hann', 'hanning'}
        window = 0.5 - 0.5 * cos(2 * pi * (0:n - 1).' / max(n - 1, 1));
    case 'rectangular'
        window = ones(n, 1);
    otherwise
        error('ex18_make_ascan_iczt:BadWindow', 'Unsupported window: %s.', opts.Window);
end
end

% =========================================================================
% 预期延迟（用于图上标记和验证）
% =========================================================================

function expected = expected_delays_iczt(cfg)
%EXPECTED_DELAYS_ICZT 保存用于图上标记和验证的理论时延。
%
%   DirectDelayS  : 天线直耦预计延迟。
%   SurfaceDelayS : 地表反射预计延迟。
%   Targets       : 结构体数组，每个目标包含完整参数和延迟。
%   TargetDelayS  : 向后兼容——指向 targets(1).delay_s。
expected = struct();
expected.DirectDelayS = cfg.gpr.direct_delay_s;
expected.SurfaceDelayS = cfg.gpr.surface_delay_s;
expected.TargetDelayS = cfg.gpr.targets(1).delay_s;
expected.TargetPathM = cfg.gpr.targets(1).path_m;
expected.TargetEquivalentDepthM = cfg.gpr.targets(1).path_m / 2;
expected.TargetCenterDepthM = cfg.gpr.targets(1).depth_m;
expected.Targets = cfg.gpr.targets;
expected.SoilVelocityMps = cfg.gpr.soil_velocity_mps;
expected.ScanXM = cfg.gpr.scan_x_m;
end

% =========================================================================
% 目标验证
% =========================================================================

function results = verify_target_iczt(results, cfg, opts)
%VERIFY_TARGET_ICZT 在理论目标附近寻找 A-scan 峰值。
%
%   不能直接取整个 A-scan 的最大峰，因为直耦、地表或旁瓣可能比目标强。
%   所以这里只在 TargetDelayS +/- TargetWindowNs/2 的窗口内找最大值，
%   用它作为 observed target peak。
%
%   容差计算：
%     - 频率带宽越窄，A-scan 峰越宽。这里用 1/Bandwidth 作为基本时间分辨率。
%     - 综合容差 = max(TargetWindowNs/2, 1.25 / Bandwidth)
%     - 1.25 留出对 sinc 主瓣展宽的余量。
%
%   验证结果:
%     - Pass = (|delay_error_s| <= tolerance_s)
%     - 失败时打印 "CHECK" 而非 "PASS"，提示用户检查参数。

target_delay_s = results.Expected.TargetDelayS;
target_window_s = opts.TargetWindowNs * 1e-9;
mask = results.TimeAxisS >= target_delay_s - target_window_s / 2 & ...
    results.TimeAxisS <= target_delay_s + target_window_s / 2;
if ~any(mask)
    error('ex18_make_ascan_iczt:BadTargetWindow', 'Target verification window is empty.');
end

idx_all = find(mask);
[peak_amp, local_idx] = max(results.Amplitude(mask));
peak_idx = idx_all(local_idx);
observed_delay_s = results.TimeAxisS(peak_idx);
observed_depth_m = cfg.gpr.soil_velocity_mps * observed_delay_s / 2;
delay_error_s = observed_delay_s - target_delay_s;
depth_error_m = observed_depth_m - results.Expected.TargetEquivalentDepthM;

% 时间分辨率由 1/Bandwidth 决定。
time_resolution_s = 1 / max(results.BandwidthHz, eps);
tolerance_s = max(target_window_s / 2, 1.25 * time_resolution_s);

verification = struct();
verification.TargetWindowNs = opts.TargetWindowNs;
verification.TargetPeakAmplitude = peak_amp;
verification.ObservedTargetDelayS = observed_delay_s;
verification.ObservedTargetDepthM = observed_depth_m;
verification.DelayErrorS = delay_error_s;
verification.DepthErrorM = depth_error_m;
verification.TimeResolutionS = time_resolution_s;
verification.ToleranceS = tolerance_s;
verification.Pass = abs(delay_error_s) <= tolerance_s;
results.Verification = verification;
end

% =========================================================================
% 绘图
% =========================================================================

function results = plot_ascan_results_iczt(results, opts)
%PLOT_ASCAN_RESULTS_ICZT 绘制 A-scan 时延域结果图（ICZT 版本）。
%
%   图中包含:
%      - A-scan 曲线（时延 vs 幅度，线性）
%      - 彩色竖线标记：surface / direct / target / observed
%      - 图例说明各标记含义
%
%   频域幅度和相位仍保存在 results.Response / results.ResponseCorrected 中，
%   默认图窗只显示时延域 A-scan，避免干扰观察目标回波。

% === 确保输出目录存在 ===
if opts.SaveResults && exist(opts.OutputDir, 'dir') ~= 7
    mkdir(opts.OutputDir);
end

% === 限制横轴显示范围 ===
max_delay_ns = opts.MaxPlotDelayNs;
plot_mask = results.TimeAxisS <= max_delay_ns * 1e-9;

% === 创建图窗 ===
fig = figure('Name', 'ex18 A-scan (ICZT)', 'Visible', opts.Visible, 'Color', 'w');
ax = axes('Parent', fig);
hold(ax, 'on');

% === 主曲线：时延 vs 幅度（线性） ===
% ICZT 版本用线性幅度，更直观反映各分量相对强度。
time_ns = results.TimeAxisS(plot_mask) * 1e9;
plot(ax, time_ns, results.Amplitude(plot_mask), ...
    'Color', [0.12 0.30 0.65], 'LineWidth', 0.9);
grid on;
xlabel('Delay (ns)');
ylabel('A-scan amplitude (linear)');

% === 图标题：含 ICZT 关键参数 ===
% dt (延迟步长) 是 ICZT 区别于 IFFT 的核心参数，显示在图标题便于调试。
title_str = sprintf(...
    'ex18 A-scan (ICZT)  |  dt=%.4g ns  |  source: %s  |  BG: %s', ...
    results.DelayStepS * 1e9, results.Source, results.BackgroundMode);
title(title_str, 'Interpreter', 'none');

% === 延迟标记线（彩色 + 图例） ===
delay_markers = {
    results.Expected.SurfaceDelayS,    'surface (地表)',   [0.85 0.33 0.10];
    results.Expected.DirectDelayS,     'direct (直耦)',    [0.10 0.55 0.90];
};

target_colors = [0.10 0.75 0.20; 0.20 0.55 0.10; 0.05 0.60 0.05];
nt = numel(results.Expected.Targets);
for k = 1:nt
    delay_markers = [delay_markers; ...
        {results.Expected.Targets(k).delay_s, ...
         sprintf('target %d (%.2fm)', k, results.Expected.Targets(k).depth_m), ...
         target_colors(min(k, size(target_colors,1)), :)}];  %#ok<AGROW>
end
delay_markers = [delay_markers; ...
        {results.Verification.ObservedTargetDelayS, 'observed (实测)', [0.85 0.10 0.55]}];

legend_entries = {};
legend_handles = [];

for i = 1:size(delay_markers, 1)
    delay_ns = delay_markers{i,1} * 1e9;
    label = delay_markers{i,2};
    color = delay_markers{i,3};
    h = plot(ax, [delay_ns delay_ns], ylim(ax), ...
        'Color', color, 'LineStyle', '--', 'LineWidth', 1.0);
    legend_handles = [legend_handles, h];  %#ok<AGROW>
    legend_entries = [legend_entries; {label}];  %#ok<AGROW>
end

legend(ax, legend_handles, legend_entries, 'Location', 'northwest', 'FontSize', 8);

% === 保存图像 ===
if opts.SaveResults
    results_file = fullfile(opts.OutputDir, ['ex18_ascan_iczt_' opts.Timestamp '.png']);
    try
        exportgraphics(fig, results_file, 'Resolution', 160);
    catch
        saveas(fig, results_file);
    end
    results.FigureFile = results_file;
end

% === 批处理模式关闭图窗 ===
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

% =========================================================================
% 命令行输出
% =========================================================================

function print_summary_iczt(results)
%PRINT_SUMMARY_ICZT 在命令行打印本次 A-scan 的关键结果。
%
%   打印内容包括:
%     - 方法 (ICZT)、时延窗口、点数
%     - 数据来源（仿真日志/模型参考）
%     - 是否做了背景扣除及复数 scale
%     - 频点范围、步进
%     - 理论/观测目标延迟、深度、误差
%     - 容差和 PASS/CHECK
%     - 输出文件路径
%
%   如果结果是 CHECK，通常需要检查：背景扣除、采样率、频点数、
%   TargetWindowNs 或土壤/目标参数是否和预期一致。
v = results.Verification;
e = results.Expected;
fprintf('ex18 A-scan (ICZT) generated.\n');
fprintf('Method: ICZT, delay range: %.3f-%.3f ns, step: %.4g ns, points: %d\n', ...
    results.DelayStartS * 1e9, results.DelayStopS * 1e9, ...
    results.DelayStepS * 1e9, results.NumDelayPoints);
fprintf('Source: %s\n', results.Source);
if isfield(results, 'Background') && results.Background.Applied
    fprintf('Background: model background subtracted, complex scale = %.4g%+.4gj\n', ...
        real(results.Background.Scale), imag(results.Background.Scale));
else
    fprintf('Background: none\n');
end
fprintf('Frequency points: %d, %.3f-%.3f MHz, df = %.3f MHz\n', ...
    numel(results.FrequencyHz), results.FrequencyHz(1) / 1e6, ...
    results.FrequencyHz(end) / 1e6, results.DfHz / 1e6);
fprintf('Expected target delays:\n');
for k = 1:numel(e.Targets)
    fprintf('  Target %d: %.3f ns (x=%.2f m, depth=%.2f m)\n', ...
        k, e.Targets(k).delay_s * 1e9, ...
        e.Targets(k).center_x_m, e.Targets(k).depth_m);
end
fprintf('Observed target-window peak: %.3f ns, equivalent depth: %.3f m\n', ...
    v.ObservedTargetDelayS * 1e9, v.ObservedTargetDepthM);
fprintf('Target delay error: %.3f ns, depth error: %.3f m, tolerance: %.3f ns -> %s\n', ...
    v.DelayErrorS * 1e9, v.DepthErrorM, v.ToleranceS * 1e9, pass_text_iczt(v.Pass));
if isfield(results, 'FigureFile') && ~isempty(results.FigureFile)
    fprintf('Figure: %s\n', results.FigureFile);
end
if isfield(results, 'MatFile') && ~isempty(results.MatFile)
    fprintf('MAT: %s\n', results.MatFile);
end
end

function text = pass_text_iczt(tf)
%PASS_TEXT_ICZT 把逻辑验证结果转换成命令行可读文本。
if tf
    text = 'PASS';
else
    text = 'CHECK';
end
end

function tf = base_has_var_iczt(name)
%BASE_HAS_VAR_ICZT 判断 base workspace 中是否存在指定变量。
%   ex18 的模型和后处理大量通过 base workspace 交换变量，因此这里封装
%   exist(..., 'var')，避免每处都直接写 evalin。
tf = evalin('base', sprintf('exist(''%s'', ''var'') == 1', name));
end

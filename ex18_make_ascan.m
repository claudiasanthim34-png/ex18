function results = ex18_make_ascan(varargin)
% 时窗--ASCAN_MAX_PLOT_DELAY_NS

%EX18_MAKE_ASCAN 从 ex18 当前单位置模型生成 A-scan。
%
%   ========== SFCW 雷达 A-scan 成像原理 ==========
%
%   步进频率连续波（SFCW）雷达逐个频率点发射、接收，在频域完成测量，再通过
%   IFFT 变换到时延域（即 A-scan）。其物理本质是：不同时延的回波在频域中
%   体现为不同斜率的线性相位。
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
%   把多个等间隔频率点上的 H(f) 做 IFFT，就能在时延轴上得到一个峰值，
%   峰值位置就是 tau。
%
%   多目标/多路径时，H(f) 是多个复正弦的叠加。不同时延对应不同频率
%   （相位斜率），IFFT 可将它们分开，形成多个峰值，这就是 A-scan。
%
%   ========== 距离分辨率与不模糊距离 ==========
%
%   距离分辨率: dR = v / (2 * B) = v / (2 * N * df)
%       v: 介质中波速
%       B = N * df: 总带宽（N 个频点，步进 df Hz）
%       IFFT 只能分开时延差 >= 1/B 的两个回波，对应距离差 dR。
%       本模型 B = 501 * 0.3MHz = 150.3 MHz, v_soil ≈ 0.3/√9 ≈ 0.1 m/ns,
%       dR ≈ 0.1/(2*150.3e6) ≈ 0.33 m。
%
%   不模糊距离: Ru = v / (2 * df)
%       频率间隔 df 决定了 IFFT 结果在时域的周期: T_period = 1/df。
%       时延超过 1/df 的回波会被"卷绕"到 0~1/df 区间内。
%       本模型 df = 0.3 MHz, Ru ≈ 0.1/(2*0.3e6) ≈ 167 m，远超目标深度。
%
%   ========== 处理链 ==========
%       1. 读取或运行单位置 Simulink 仿真。
%       2. 同步解调: 在每个 SFCW PRI 的稳定区间内做
%          tone_k = 2 * mean( y(t) * exp(-j2*pi*f_k*t) )
%          得到该频点的复幅度。系数 2 补偿实数余弦的 1/2 幅度衰减。
%       3. 发射和接收分别解调，相除得到频域通道响应:
%          H(f_k) = RX_tone(f_k) / SRC_tone(f_k)
%          相除的目的: 抵消信号源自身的幅度/相位不平坦，只保留通道分量。
%       4. 背景扣除: 用解析土壤模型生成不含目标的"背景频响"，
%          通过最小二乘匹配幅度/相位后，从 H(f) 中减去:
%          H_bgsub(f) = H(f) - scale * H_background(f)
%          扣除直耦、地表反射和弱杂波，突出目标。
%       5. 加窗 + IFFT: 对等间隔 H(f_k) 做 Hann 加窗抑制旁瓣，
%           零填充到 NFFT 点后 IFFT 得到时延域 A-scan:
%          ascan(tau) = IFFT{ H(f) * window(f) }
%       6. 目标检测: 在理论目标时延附近 ±TargetWindowNs/2 窗口内
%          找最大峰，验证实际峰位是否在容差范围内。
%
%   results = ex18_make_ascan() 会优先使用现有仿真日志。如果没有日志，
%   但 base workspace 中已有 gpr_soil_model，则使用解析模型频响直接
%   生成参考 A-scan。
%
%   results = ex18_make_ascan('RunSimulation', true, 'SampleRate', 1e9)
%   会先以 1 GHz 采样率运行当前单位置模型，再从日志中提取 A-scan。

work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);

% 时窗等参数的手动默认值在 parse_opts() 函数开头，直接打开修改即可。
opts = parse_opts(varargin{:});
opts.Timestamp = datestr(now, 'yyyymmdd_HHMMSS');
if opts.RunSimulation
    % 如果用户要求先仿真，则临时修改模型 InitFcn，运行完成后恢复。
    % 这样可以避免为了做一次 A-scan 验证而保存/污染 .slx 文件。
    run_single_position_simulation(opts);
end

% 确保 base workspace 中至少有 cfg、sfw_meta、sfw_src_ts 等基础变量。
% 如果用户还没手动运行 setup_ex18_sfw，这里会自动补一次 setup。
ensure_workspace_ready();
[cfg, meta] = read_context();

% 获取频域响应 H(f)。优先从仿真日志中估计，缺日志时退回到
% gpr_soil_model 的解析频响。frequency_hz 是实际参与 IFFT 的频率轴。
[frequency_hz, response, source_label] = get_frequency_response(cfg, meta, opts);
raw_response = response;

% 背景处理用于把直耦、地表反射和弱杂波尽量扣掉，让目标回波更清楚。
% 默认 BackgroundMode = 'model'，即使用 ex18_make_ex08_soil_fir 生成的
% 模型分量 background_response 做背景扣除。
[response, background] = apply_background_processing(frequency_hz, response, opts);

% 构造 A-scan：先做前端延迟补偿和加窗，再 IFFT 到时延域。
results = build_ascan(frequency_hz, response, cfg, opts, source_label);
results.RawResponse = raw_response;
results.Background = background;

% 在理论目标延迟附近找最大峰，给出延迟/深度误差和 PASS/CHECK 标志。
results = verify_target(results, cfg, opts);

% 只画最终时延域 A-scan。频域幅度和相位仍保存在 results 中。
results = plot_ascan_results(results, opts);

if opts.SaveResults
    % 保存 results 结构体，方便后续不重新仿真也能读出频响、A-scan、验证结果。
    if exist(opts.OutputDir, 'dir') ~= 7
        mkdir(opts.OutputDir);
    end
    results.MatFile = fullfile(opts.OutputDir, ['ex18_ascan_' opts.Timestamp '.mat']);
    save(results.MatFile, 'results');
end

print_summary(results);
end

function opts = parse_opts(varargin)
%PARSE_OPTS 解析本脚本支持的可选参数。
%   这些参数可以在命令行里临时覆盖，例如：
%       ex18_make_ascan('RunSimulation', true, 'SampleRate', 1e9)
%   注意：这里解析出来的是脚本运行选项，不会写回 default_cfg()。

% ===== 手动配置区 —— 直接修改下面的数值即可改变默认值 =====
% A-scan 横轴最大显示延迟，单位 ns。改大看深层，改小看浅层。
cfg_auto_MaxPlotDelayNs = 80;

parser = inputParser;

% RunSimulation=true 时，脚本会先调用 sim('ex18_sfw_top')。
% false 时，脚本只使用当前 base workspace 中已有的日志或模型频响。
parser.addParameter('RunSimulation', false, @(x) islogical(x) || isnumeric(x));

% StepCount 控制仿真时实际生成多少个 SFCW 频点。
% NaN 表示不覆盖 setup_ex18_sfw 的默认值，即完整 501 点。
parser.addParameter('StepCount', NaN, @(x) isnumeric(x) && isscalar(x));

% SampleRate 控制仿真采样率覆盖值。[] 表示使用 setup_ex18_sfw 默认采样率。
% 对调试而言，1 GHz 常用于快速验证；默认高采样率会明显增加日志体积。
parser.addParameter('SampleRate', [], @(x) isempty(x) || (isnumeric(x) && isscalar(x) && x > 0));

% InputSignal 是用于提取 A-scan 的接收端日志变量。
% 默认 rx_antenna_log 对应接收天线原始输出，适合直接估计 GPR 通道 H(f)。
parser.addParameter('InputSignal', 'rx_antenna_log', @(x) ischar(x) || isstring(x));

% NFFT 是 IFFT 点数。点数越大，时延轴显示越密，但真实分辨率仍由带宽决定。
parser.addParameter('NFFT', 4096, @(x) isnumeric(x) && isscalar(x) && x >= 1);

% Window 控制频域加窗。hann 可降低旁瓣；rectangular 保留原始频响但旁瓣更高。
parser.addParameter('Window', 'hann', @(x) ischar(x) || isstring(x));

% BackgroundMode='model' 时扣除模型背景；'none' 时直接对原始响应 IFFT。
parser.addParameter('BackgroundMode', 'model', @(x) ischar(x) || isstring(x));

% 每个频点的 PRI 内，滤波器和混频器会有过渡过程，所以只取后半段稳定区间
% 做复幅度平均。ToneUseFraction 表示使用每个脉冲后段的比例。
parser.addParameter('ToneUseFraction', 0.45, @(x) isnumeric(x) && isscalar(x) && x > 0 && x <= 1);

% 避开每个 PRI 最末尾一点点样本，减少频点切换边界对解调的污染。
parser.addParameter('ToneEndGuardFraction', 0.05, @(x) isnumeric(x) && isscalar(x) && x >= 0 && x < 1);

% 前端模型中包含约 3.8 ns 的等效群时延。这里先补偿掉，
% 让 A-scan 横轴更接近真实传播路径延迟。
parser.addParameter('FrontendDelayCorrectionS', 3.8e-9, @(x) isnumeric(x) && isscalar(x) && x >= 0);

% 目标验证时，只在理论目标延迟附近这个窗口内找峰，避免直耦或旁瓣被误判。
parser.addParameter('TargetWindowNs', 16, @(x) isnumeric(x) && isscalar(x) && x > 0);

% 图中 A-scan 横轴最大显示延迟。只影响显示，不影响计算和保存结果。
parser.addParameter('MaxPlotDelayNs', cfg_auto_MaxPlotDelayNs, @(x) isnumeric(x) && isscalar(x) && x > 0);

% 是否保存 ex18_ascan.png 和 ex18_ascan.mat。
parser.addParameter('SaveResults', true, @(x) islogical(x) || isnumeric(x));

% Visible='off' 适合批处理或自动验证；Visible='on' 会弹出图窗。
parser.addParameter('Visible', 'on', @(x) ischar(x) || isstring(x));

% 输出目录，默认放在 ex18/output。
parser.addParameter('OutputDir', fullfile(fileparts(mfilename('fullpath')), 'output'), ...
    @(x) ischar(x) || isstring(x));
parser.parse(varargin{:});

opts = parser.Results;
% 后处理时统一数据类型，避免后续字符串/逻辑/整数处理出现版本差异。
opts.RunSimulation = logical(opts.RunSimulation);
opts.StepCount = round(opts.StepCount);
opts.InputSignal = char(opts.InputSignal);
opts.NFFT = 2 ^ nextpow2(max(1, round(opts.NFFT)));
opts.Window = lower(char(opts.Window));
opts.BackgroundMode = lower(char(opts.BackgroundMode));
opts.SaveResults = logical(opts.SaveResults);
opts.Visible = char(opts.Visible);
opts.OutputDir = char(opts.OutputDir);
end

function run_single_position_simulation(opts)
%RUN_SINGLE_POSITION_SIMULATION 临时运行当前 ex18 顶层模型。
%   这里不直接改 .slx 文件，而是：
%       1. 记住原来的 InitFcn 和 Dirty 状态。
%       2. 临时把 InitFcn 改成带 StepCount/SampleRate 的 setup_ex18_sfw 调用。
%       3. sim 完成后把日志复制回 base workspace。
%       4. 函数退出时自动恢复原 InitFcn 和 Dirty 状态。
model = 'ex18_sfw_top';
model_file = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);
load_system(model_file);

% 保护用户模型状态。即使仿真中出错，onCleanup 也会尽量恢复。
old_init = get_param(model, 'InitFcn');
old_dirty = get_param(model, 'Dirty');
cleanup = onCleanup(@() restore_model_init(model, old_init, old_dirty));

% 只把用户显式传入的覆盖项写进临时 InitFcn。
% 例如 SampleRate=[] 时，不覆盖 setup_ex18_sfw.m 的默认采样率。
setup_args = {};
if ~isnan(opts.StepCount)
    setup_args(end + 1:end + 2) = {'StepCount', opts.StepCount};
end
if ~isempty(opts.SampleRate)
    setup_args(end + 1:end + 2) = {'SampleRate', opts.SampleRate};
end
init_cmd = setup_call_text(setup_args);

set_param(model, 'InitFcn', init_cmd);

% ReturnWorkspaceOutputs='on' 让 To Workspace 日志进入 sim_out。
% 后面再复制到 base workspace，保持和手动 Run 后的使用体验一致。
sim_out = sim(model, 'ReturnWorkspaceOutputs', 'on');
copy_sim_outputs_to_base(sim_out);
end

function text = setup_call_text(args)
%SETUP_CALL_TEXT 把 {'Name', value, ...} 转成可写入 InitFcn 的 MATLAB 文本。
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

function copy_sim_outputs_to_base(sim_out)
%COPY_SIM_OUTPUTS_TO_BASE 把 Simulink 日志变量复制到 base workspace。
%   ex18_make_ascan 后续会从 base workspace 读取 rx_antenna_log 和
%   sfw_src_ts。这里复制的几个变量都是模型中的 To Workspace 日志。
names = {'rf_out_log', 'tap_up_log', 'rx_down_if_log', 'rx_iq_baseband_log', 'rx_antenna_log'};
for k = 1:numel(names)
    try
        value = sim_out.get(names{k});
    catch
        continue;
    end
    assignin('base', names{k}, value);
end
end

function restore_model_init(model, old_init, old_dirty)
%RESTORE_MODEL_INIT 恢复模型 InitFcn 和 Dirty 标志。
%   这样本脚本临时运行仿真不会改变用户手动保存的模型排版或参数。
if bdIsLoaded(model)
    set_param(model, 'InitFcn', old_init);
    set_param(model, 'Dirty', old_dirty);
end
end

function ensure_workspace_ready()
%ENSURE_WORKSPACE_READY 确保基础配置变量存在。
%   cfg 保存 ex18 当前配置，sfw_meta 保存 SFCW 时间轴、频率轴、PRI 等
%   派生信息。没有这些变量就无法按频点分段解调。
if ~base_has_var('cfg') || ~base_has_var('sfw_meta')
    setup_ex18_sfw();
end
end

function [cfg, meta] = read_context()
%READ_CONTEXT 从 base workspace 读取配置和 SFCW 元数据。
%   使用 evalin 是为了和 Simulink/From Workspace 的变量来源保持一致。
cfg = evalin('base', 'cfg');
meta = evalin('base', 'sfw_meta');
end

function [frequency_hz, response, source_label] = get_frequency_response(cfg, meta, opts)
%GET_FREQUENCY_RESPONSE 得到用于 IFFT 的复频域响应 H(f)。
%   优先级如下：
%       1. 如果 base workspace 中有仿真日志 opts.InputSignal 和 sfw_src_ts，
%          就从时域日志中按频点同步解调得到 H(f)。
%       2. 如果没有日志，但有 gpr_soil_model，就直接使用模型解析频响。
%   第 1 种更接近当前 Simulink 时域链路，第 2 种适合快速检查成像逻辑。
frequency_hz = meta.freq_hz(:);

if base_has_var(opts.InputSignal) && base_has_var('sfw_src_ts')
    % 从时域仿真记录中提取接收复幅度和发射复幅度，再相除得到通道响应。
    raw_rx = evalin('base', opts.InputSignal);
    raw_src = evalin('base', 'sfw_src_ts');
    response = response_from_rx_log(raw_rx, raw_src, frequency_hz, meta, opts);
    source_label = sprintf('simulation log: %s / sfw_src_ts', opts.InputSignal);
    return;
end

if base_has_var('gpr_soil_model')
    % 没有仿真日志时，使用 ex18_make_ex08_soil_fir 保存的频域模型响应。
    % 这个路径不经过 RF Blockset 时域仿真，所以速度很快。
    model = evalin('base', 'gpr_soil_model');
    response = response_from_soil_model(model, frequency_hz);
    source_label = 'model response: gpr_soil_model.sfcw_response';
    return;
end

error('ex18_make_ascan:NoResponseSource', ...
    ['No usable simulation log or gpr_soil_model was found. Run sim(''ex18_sfw_top'') first, ' ...
    'or call ex18_make_ascan(''RunSimulation'', true).']);
end

function response = response_from_rx_log(raw_rx, raw_src, frequency_hz, meta, opts)
%RESPONSE_FROM_RX_LOG 从时域日志估计 SFCW 复频响。
%
%   ===== 同步解调原理（SFCW 复幅度提取）=====
%
%   SFCW 的每个 PRI（脉冲重复周期）内只发射一个频点 f_k。
%   对该 PRI 内的接收时域波形 y_k(t)，用复指数 exp(-j2*pi*f_k*t) 相乘后取平均：
%       tone_k = 2 * mean_{t in PRI}[ y_k(t) * exp(-j2*pi*f_k*t) ]
%
%   为什么乘 exp(-j2*pi*f_k*t)？
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
%
%   ===== 为什么只用 PRI 后半段？ =====
%   每个频点刚开始时，RF 链路的滤波器（如 BPF、LPF）处于瞬态过渡过程，
%   输出幅度和相位尚未稳定。取 PRI 后段（由 ToneUseFraction 和
%   ToneEndGuardFraction 控制）可以避开瞬态，提高解调精度。
[rx_time_s, rx_value] = extract_signal(raw_rx, opts.InputSignal);
[src_time_s, src_value] = extract_signal(raw_src, 'sfw_src_ts');

rx_tones = extract_step_tones(rx_time_s, rx_value, frequency_hz, meta, opts);
src_tones = extract_step_tones(src_time_s, src_value, frequency_hz, meta, opts);

% 如果某些源频点估计接近 0（信号太弱、采样率不足或 PRI 太短），
% 除法 rx_tones(good)/src_tones(good) 会放大噪声。所以先过滤掉
% 弱源频点，后面再用 fillmissing_complex 插值补齐。
good = abs(src_tones) > max(abs(src_tones)) * 1e-6;
if nnz(good) < numel(frequency_hz)
    warning('ex18_make_ascan:WeakReference', ...
        'Only %d/%d source tone estimates were above threshold.', nnz(good), numel(frequency_hz));
end

response = nan(size(rx_tones));
response(good) = rx_tones(good) ./ src_tones(good);
% 仿真日志偶尔可能因为过短或边界问题缺少个别频点，这里用复数插值补齐。
% 线性插值对复数的实部和虚部分别等价，保留了幅相连续性。
response = fillmissing_complex(response);
end

function response = response_from_soil_model(model, frequency_hz)
%RESPONSE_FROM_SOIL_MODEL 从 gpr_soil_model 中取出 SFCW 频点响应。
%   优先使用 sfcw_response，因为它是在真实 SFCW 频率点上直接计算的。
%   如果旧版本模型没有 sfcw_response，则退回到 FIR 频率网格插值。
if isfield(model, 'sfcw_response') && isfield(model, 'sfcw_frequency_hz')
    response = interp1(model.sfcw_frequency_hz(:), model.sfcw_response(:), ...
        frequency_hz(:), 'linear', 'extrap');
elseif isfield(model, 'frequency_hz') && isfield(model, 'response')
    response = interp1(model.frequency_hz(:), model.response(:), ...
        frequency_hz(:), 'linear', 'extrap');
else
    error('ex18_make_ascan:BadSoilModel', ...
        'gpr_soil_model does not contain a usable frequency response.');
end
end

function [response, background] = apply_background_processing(frequency_hz, response, opts)
%APPLY_BACKGROUND_PROCESSING 执行背景扣除处理。
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
%   这是复数域的最小二乘问题（complex_scale 函数）。
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
        % 不做背景扣除，直接对原始 H(f) 做 IFFT。
        % 这时 A-scan 最前面的强峰通常是直耦和地表反射，目标峰往往被遮盖。
        return;
    case 'model'
        if ~base_has_var('gpr_soil_model')
            warning('ex18_make_ascan:NoBackgroundModel', ...
                'BackgroundMode=model requested, but gpr_soil_model is missing. Using raw response.');
            return;
        end
        model = evalin('base', 'gpr_soil_model');
        if ~isfield(model, 'sfcw_parts') || ~isfield(model.sfcw_parts, 'background_response')
            warning('ex18_make_ascan:NoBackgroundParts', ...
                'gpr_soil_model has no component background response. Using raw response.');
            return;
        end

        % model_total    = 模型完整频响（直耦 + 地表 + 杂波 + 目标）
        % model_background = 模型背景频响（直耦 + 地表 + 杂波，不含目标）
        % scale 是复数最小二乘比例，匹配模型的幅度和相位到仿真数据。
        model_total = response_from_soil_model(model, frequency_hz);
        model_background = interp_model_part(model, 'background_response', frequency_hz);
        scale = complex_scale(model_total, response);
        % 背景扣除: H_bgsub = H_measured - scale*H_background_model
        response = response - scale .* model_background;

        background.Applied = true;
        background.Scale = scale;
        background.Response = scale .* model_background;
    otherwise
        error('ex18_make_ascan:BadBackgroundMode', ...
            'Unsupported BackgroundMode: %s. Use ''model'' or ''none''.', opts.BackgroundMode);
end
end

function part = interp_model_part(model, name, frequency_hz)
%INTERP_MODEL_PART 取出 gpr_soil_model.sfcw_parts 中的指定分量并插值。
%   可用分量包括 background_response、target_response、direct_response 等。
if isfield(model, 'sfcw_frequency_hz') && isfield(model, 'sfcw_parts') && ...
        isfield(model.sfcw_parts, name)
    part = interp1(model.sfcw_frequency_hz(:), model.sfcw_parts.(name)(:), ...
        frequency_hz(:), 'linear', 'extrap');
else
    error('ex18_make_ascan:MissingModelPart', 'Missing model part: %s.', name);
end
end

function scale = complex_scale(reference, measured)
%COMPLEX_SCALE 复数最小二乘比例估计: measured ≈ scale * reference。
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

function tones = extract_step_tones(time_s, value, frequency_hz, meta, opts)
%EXTRACT_STEP_TONES 对每个 SFCW 频点做同步解调，提取复幅度。
%
%   ===== 算法推导 =====
%   输入 time_s/value 是一整段时域波形，包含 N 个频点，每个频点占一个 PRI。
%   meta 中记录了每个 PRI 的起止时间。
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
        % 样本仍不足时保留 NaN，后续 fillmissing_complex 会尝试插值补齐。
        continue;
    end

    t = time_s(idx);
    y = value(idx);
    % 同步解调: 乘 exp(-j2*pi*f_k*t) 把信号搬移到 DC，再取平均。
    % 系数 2 用于补偿实数余弦信号只有一半功率在正频率分量。
    tones(k) = 2 * mean(y(:) .* exp(-1i * 2 * pi * frequency_hz(k) .* t(:)));
end
end

function value = fillmissing_complex(value)
%FILLMISSING_COMPLEX 对缺失复频点做线性插值。
%   A-scan 的 IFFT 要求频域向量不能有 NaN/Inf。这里分别等价地对复数
%   序列做线性插值，保留幅相连续性。若有效点太少，则直接报错。
bad = ~isfinite(real(value)) | ~isfinite(imag(value));
if ~any(bad)
    return;
end

idx = (1:numel(value)).';
good = ~bad;
if nnz(good) < 2
    error('ex18_make_ascan:TooFewTones', 'Too few valid tone estimates for A-scan.');
end
value(bad) = interp1(idx(good), value(good), idx(bad), 'linear', 'extrap');
end

function [time_s, value] = extract_signal(raw, var_name)
%EXTRACT_SIGNAL 统一读取 timeseries 和 To Workspace 结构体格式。
%   Simulink 中不同日志块可能输出 timeseries 或 Structure With Time。
%   本函数把它们统一整理成两个列向量：time_s 和 value。
if isa(raw, 'timeseries')
    time_s = raw.Time;
    value = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    time_s = raw.time;
    value = raw.signals.values;
else
    error('ex18_make_ascan:BadSignal', 'Unsupported signal format for %s.', var_name);
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

n = min(numel(time_s), numel(value));
time_s = time_s(1:n);
value = value(1:n);

finite_idx = isfinite(time_s) & isfinite(value);
% 去掉非有限值，避免后续解调平均时污染复幅度估计。
time_s = time_s(finite_idx);
value = value(finite_idx);
end

function results = build_ascan(frequency_hz, response, cfg, opts, source_label)
%BUILD_ASCAN 将频域响应转换成时延域 A-scan（IFFT 成像）。
%
%   ===== SFCW 成像的核心：IFFT =====
%
%   SFCW 雷达在 N 个等间隔频率 f_k = f_0 + k*df 上测量复频响 H(f_k)。
%   已知: H(f_k) = sum_m{ a_m * exp(-j*2*pi*f_k*tau_m) }
%   即每个目标在频域贡献一个复正弦分量，复数幅度 a_m 反映目标反射强度，
%   相位斜率 -2*pi*tau_m 由目标时延 tau_m 决定。
%
%   对 H(f_k) 做 IFFT:
%       ascan[n] = IFFT{H(f_k)}_n = sum_k{ H(f_k) * exp(+j2*pi*k*n/N) }
%   将 tau_k = n / (N*df) 代入，得到:
%       ascan(tau) ≈ sum_m{ a_m * delta(tau - tau_m) }
%   其中 delta 是"展宽的冲激"（受限于有限带宽的 sinc 形峰）。
%
%   因此 IFFT 把频域中不同斜率的复正弦"聚焦"到时延域的不同位置，
%   形成一组峰值——这就是 A-scan。峰值位置 = 目标时延，峰值高度 = 目标反射强度。
%
%   ===== Hann 加窗 =====
%   有限带宽 + 矩形窗 → IFFT 旁瓣为 sinc 函数，第一旁瓣约 -13 dB。
%   旁瓣会掩盖弱目标（如深层管道）。Hann 窗将旁瓣压到约 -32 dB，
%   代价是主瓣宽度增大 ~1.6 倍，即距离分辨率适度降低。
%
%   ===== 零填充 =====
%   在 H(f) 末尾补零到 NFFT 点后做 IFFT，相当于对时域 ascan[n] 做
%   sinc 插值。它让图上时延采样更密（曲线更平滑），但不会提高
%   由总带宽决定的分辨率极限 dR = v/(2*B)。
%
%   ===== 前端延迟补偿 =====
%   RF 前端有固定的群时延 tau0 ≈ 3.8 ns（滤波器、放大器等），
%   频域等价于 H(f) 上额外乘 exp(-j2*pi*f*tau0)。
%   在 IFFT 前乘 exp(+j2*pi*f*tau0) 可补偿这个延迟，
%   使目标峰出现在物理传播时延附近，而非 tau0 偏移后的位置。
%
%   ===== 时延轴和深度轴的关系 =====
%   双程时延 tau:  电磁波从 Tx 出发，经地下目标反射，回到 Rx 的总时间。
%   等效深度:      depth = v_soil * tau / 2
%   除以 2 是因为 depth 是单程距离（电磁波走了来回 2*depth）。
frequency_hz = frequency_hz(:);
response = response(:);
df_hz = mean(diff(frequency_hz));                % 频率步进 (Hz)
bandwidth_hz = frequency_hz(end) - frequency_hz(1);  % 总带宽 (Hz)

% Hann 窗压低 IFFT 旁瓣。代价是主瓣变宽，距离分辨率下降约 60%。
window = make_window(numel(response), opts.Window);

% 前端延迟补偿。补偿 exp(+j2*pi*f*tau0)，抵消 RF 链路固定群时延。
delay_correction_s = opts.FrontendDelayCorrectionS;
response_corrected = response .* exp(1i * 2 * pi * frequency_hz * delay_correction_s);

% IFFT 点数至少要覆盖全部频点。零填充让时延采样更细，不改变分辨率。
nfft = max(opts.NFFT, 2 ^ nextpow2(numel(response)));
ascan = ifft(response_corrected .* window, nfft);

% 等间隔频率采样 → IFFT 后的时延轴
% 每个 IFFT bin 的时延: dt = 1/(NFFT * df)
% 总时间窗口: T_max = 1/df（不模糊时延范围）
time_axis_s = (0:nfft - 1).' / (nfft * df_hz);
depth_axis_m = cfg.gpr.soil_velocity_mps * time_axis_s / 2;
amplitude = abs(ascan);

% 归一化到最大值 0 dB，便于观察相对反射强度。
% 注意: 这是相对值，不代表绝对 RCS 或雷达方程中的功率。
amplitude_db = 20 * log10(amplitude / max(amplitude + eps) + eps);

results = struct();
results.Source = source_label;           % 数据来源（仿真日志/模型参考）
results.FrequencyHz = frequency_hz;      % SFCW 频率轴 (Hz)
results.Response = response;            % 背景扣除后的频响 H(f)
results.ResponseCorrected = response_corrected;  % 经延迟补偿的频响
results.Window = window;                % 使用的窗函数
results.AScan = ascan;                  % IFFT 复数结果（时延域）
results.TimeAxisS = time_axis_s;        % 时延轴 (s)
results.DepthAxisM = depth_axis_m;      % 等效深度轴 (m)
results.Amplitude = amplitude;          % 幅度（线性）
results.AmplitudeDb = amplitude_db;     % 幅度 (dB, 归一化)
results.NFFT = nfft;                    % IFFT 点数
results.DfHz = df_hz;                   % 频率步进
results.BandwidthHz = bandwidth_hz;     % 总带宽
results.FrontendDelayCorrectionS = delay_correction_s;
results.BackgroundMode = opts.BackgroundMode;
results.Expected = expected_delays(cfg);  % 理论时延（用于验证）
results.FigureFile = '';
results.MatFile = '';
end

function window = make_window(n, name)
%MAKE_WINDOW 生成频域加窗向量。
%   hann: 旁瓣低，适合看目标位置。
%   rectangular: 不加窗，幅度更直接，但时延旁瓣较高。
switch lower(name)
    case {'hann', 'hanning'}
        window = 0.5 - 0.5 * cos(2 * pi * (0:n - 1).' / max(n - 1, 1));
    case 'rectangular'
        window = ones(n, 1);
    otherwise
        error('ex18_make_ascan:BadWindow', 'Unsupported window: %s.', name);
end
end

function expected = expected_delays(cfg)
%EXPECTED_DELAYS 保存用于图上标记和验证的理论时延。
%   DirectDelayS  : 天线直耦预计延迟。
%   SurfaceDelayS : 地表反射预计延迟。
%   Targets       : 结构体数组，每个目标包含 delay_s / path_m / depth_m。
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

function results = verify_target(results, cfg, opts)
%VERIFY_TARGET 在理论目标附近寻找 A-scan 峰值。
%   不能直接取整个 A-scan 的最大峰，因为直耦、地表或旁瓣可能比目标强。
%   所以这里只在 TargetDelayS +/- TargetWindowNs/2 的窗口内找最大值，
%   用它作为 observed target peak。
target_delay_s = results.Expected.TargetDelayS;
target_window_s = opts.TargetWindowNs * 1e-9;
mask = results.TimeAxisS >= target_delay_s - target_window_s / 2 & ...
    results.TimeAxisS <= target_delay_s + target_window_s / 2;
if ~any(mask)
    error('ex18_make_ascan:BadTargetWindow', 'Target verification window is empty.');
end

idx_all = find(mask);
[peak_amp, local_idx] = max(results.Amplitude(mask));
peak_idx = idx_all(local_idx);
observed_delay_s = results.TimeAxisS(peak_idx);
observed_depth_m = cfg.gpr.soil_velocity_mps * observed_delay_s / 2;
delay_error_s = observed_delay_s - target_delay_s;
depth_error_m = observed_depth_m - results.Expected.TargetEquivalentDepthM;

% 频率带宽越窄，A-scan 峰越宽。这里用 1/B 作为基本时间分辨率，
% 再和用户指定目标窗口结合，得到一个宽松但有物理意义的容差。
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

function results = plot_ascan_results(results, opts)
%PLOT_ASCAN_RESULTS 绘制 A-scan 时延域结果图。
%
%   图中包含:
%      - A-scan 曲线（时延 vs 归一化幅度，dB）
%      - 彩色竖线标记：surface / direct / target / observed
%      - 图例说明各标记含义
%
%   频域幅度和相位仍保存在 results.Response / results.ResponseCorrected 中，
%   默认图窗只显示时延域 A-scan，避免干扰观察目标回波。

% === 确保输出目录存在 ===
if opts.SaveResults && exist(opts.OutputDir, 'dir') ~= 7
    mkdir(opts.OutputDir);
end

% === 创建图窗 ===
max_delay_ns = opts.MaxPlotDelayNs;
plot_mask = results.TimeAxisS <= max_delay_ns * 1e-9;

fig = figure('Name', 'ex18 A-scan', 'Visible', opts.Visible, 'Color', 'w');
ax = axes('Parent', fig);
hold(ax, 'on');

% === 主曲线：时延 vs 幅度（线性） ===
time_ns = results.TimeAxisS(plot_mask) * 1e9;
plot(ax, time_ns, results.Amplitude(plot_mask), ...
    'Color', [0.12 0.30 0.65], 'LineWidth', 0.9);
grid on;
xlabel('Delay (ns)');
ylabel('A-scan amplitude (linear)');

% === 图标题：含关键参数 ===
title_str = sprintf(...
    'ex18 A-scan  |  source: %s  |  BG: %s  |  N_{FFT}=%d  |  BW=%.1f MHz', ...
    results.Source, results.BackgroundMode, ...
    results.NFFT, results.BandwidthHz / 1e6);
title(title_str, 'Interpreter', 'none');

% === 延迟标记线（彩色 + 图例） ===
% surface / direct 只有一条；每个目标各一条理论线和实测线。
delay_markers = {
    results.Expected.SurfaceDelayS,    'surface (地表)',   [0.85 0.33 0.10];
    results.Expected.DirectDelayS,     'direct (直耦)',    [0.10 0.55 0.90];
};

% 各目标的 target 理论线（绿色系递增） + observed 实测线（紫色系）
target_colors = [0.10 0.75 0.20; 0.20 0.55 0.10; 0.05 0.60 0.05];
obs_colors    = [0.85 0.10 0.55; 0.60 0.15 0.40; 0.50 0.10 0.70];
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

% 图例放在左上角（避开右侧波形区域）。
legend(ax, legend_handles, legend_entries, 'Location', 'northwest', 'FontSize', 8);

% === 保存图像 ===
if opts.SaveResults
    results_file = fullfile(opts.OutputDir, ['ex18_ascan_' opts.Timestamp '.png']);
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

function print_summary(results)
%PRINT_SUMMARY 在命令行打印本次 A-scan 的关键结果。
%   这里给出的 observed target-window peak 是在理论目标窗口内找到的峰。
%   如果 Result 是 CHECK，通常需要检查：背景扣除、采样率、频点数、
%   TargetWindowNs 或土壤/目标参数是否和预期一致。
v = results.Verification;
e = results.Expected;
fprintf('ex18 A-scan generated.\n');
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
    v.DelayErrorS * 1e9, v.DepthErrorM, v.ToleranceS * 1e9, pass_text(v.Pass));
if isfield(results, 'FigureFile') && ~isempty(results.FigureFile)
    fprintf('Figure: %s\n', results.FigureFile);
end
if isfield(results, 'MatFile') && ~isempty(results.MatFile)
    fprintf('MAT: %s\n', results.MatFile);
end
end

function text = pass_text(tf)
%PASS_TEXT 把逻辑验证结果转换成命令行可读文本。
if tf
    text = 'PASS';
else
    text = 'CHECK';
end
end

function tf = base_has_var(name)
%BASE_HAS_VAR 判断 base workspace 中是否存在指定变量。
%   ex18 的模型和后处理大量通过 base workspace 交换变量，因此这里封装
%   exist(..., 'var')，避免每处都直接写 evalin。
tf = evalin('base', sprintf('exist(''%s'', ''var'') == 1', name));
end

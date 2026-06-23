function ex18_probe_spectrum_analysis(varargin)
%ex18_probe_spectrum_analysis  SFCW 探头频谱综合分析主脚本。
%
%   功能概述：
%     本脚本是 ex18 SFCW GPR 工程中所有频域/时域分析的总入口。
%     它自动扫描 workspace 中所有探头变量（probe_* 或 *_log），
%     对每个探头数据执行 Step 分段幅相提取 + 宽带 FFT 频谱分析，
%     生成以下图表：
%       (1) 每个探头的时域波形 + FFT 频谱 + Step 分段谱
%       (2) 所有探头频谱叠图（频域全景对比）
%       (3) 关键模块的传递谱 H(f) = Y(f) / X(f)
%       (4) IQ 解调后的双边复频谱
%       (5) 复数基带响应 IFFT 后的 A-scan 时延/深度图
%
%   探头数据要求：
%     - 模型需事先通过 patch_add_probes 添加 ToWorkspace 探头块
%     - 探头变量保存为 'Structure With Time' 格式
%     - 各探头命名约定参见 probe_vars 列表
%     - 也兼容旧版 *_log 命名变量（rf_out_log, tap_up_log 等）
%
%   SFCW 频域分析的特殊性：
%     系统是步进频率波形，每个 PRI 发射单一频率。
%     因此不应像普通采样信号一样对整个时域序列直接 FFT。
%     正确的频域分析路径：
%       (1) Step 分段：按 PRI 截取每个频点的稳态段
%           分段裁剪——每个 PRI 前 30% 视为瞬态被丢弃
%           稳态段
%           → 同步解调 → 提取该频点的幅度(dB) + 相位(rad)
%       (2) 补充宽带 FFT：对完整时域波形做加窗 FFT
%           用于观察谐波、混频产物、镜频等 Step 分析看不到的成分
%
%   实数信号 vs 复数信号的处理差异：
%     - RF 实数信号：使用单边 FFT（0~fs/2）显示正频成分
%     - IQ 复数信号：使用 fftshift 双边频谱（-fs/2~fs/2）
%     - 混频节点：自适应判断，若为实信号走单边谱
%
%   模块传递谱 H(f) 的定义：
%     H(f) = Y(f) / X(f)
%     其中 X(f) 是模块输入端频响，Y(f) 是模块输出端频响。
%     图示：幅度 Gain/dB 和 Phase/rad 分上下两子图。
%     重点关注模块：
%       RF_Attn  — 衰减器
%       RF_VGA   — 可变增益放大器
%       RF_PA    — 功放
%       Tap_Up_BPF — 上变频带通
%       RX_Down_IF_BPF — 下变频中频带通
%       IQ_LPF_Complex — IQ 解调低通
%
%   使用示例：
%     % 方式 1：先手动运行仿真，再分析
%       setup_ex18_sfw
%       sim('ex18_sfw_top')
%       ex18_probe_spectrum_analysis
%
%     % 方式 2：自动运行仿真 + 分析（设置 StepCount=5 快速预览）
%       ex18_probe_spectrum_analysis('RunSimulation', true, ...
%           'StepCount', 5, 'SampleRate', 2e9)
%
%     % 方式 3：自定义输出目录和最大频率
%       ex18_probe_spectrum_analysis('OutputDir', 'my_results', ...
%           'MaxFreqMHz', 200)
%
%   输入参数（Name-Value 对）：
%     'RunSimulation' — 是否先运行仿真，默认 false
%     'StepCount'     — 仿真频点数量，默认 [] 使用自动
%     'SampleRate'    — 仿真采样率，默认 [] 使用预设值
%     'OutputDir'     — 图片保存目录，默认 'results'
%     'Visible'       — 是否显示 figure 窗口，默认 'on'
%     'MaxFreqMHz'    — 频谱图最大频率 (MHz)，默认 500
%     'PRIS'          — PRI 时长 (s)，默认 1e-6
%
%   输出：
%     - 所有图片保存到 OutputDir
%     - 控制台打印分析摘要

% --- 添加当前目录到 MATLAB 路径 ---
work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);

% ========================================================================
% 步骤 1：解析用户输入参数
% ========================================================================
opts = parse_probe_opts(varargin{:});

% ========================================================================
% 步骤 2：可选运行仿真
%   如果用户指定 RunSimulation=true，则通过 InitFcn 注入 StepCount
%   和 SampleRate 参数，运行一次 SFCW 仿真。
%   仿真结果（包括所有探头数据）会写入 base workspace。
% ========================================================================
if opts.RunSimulation
    run_preview_sim(opts);
end

% ========================================================================
% 步骤 3：确保 base workspace 中存在必需的配置变量
%   cfg 和 sfw_meta 是频率计划、时域参数的核心结构体。
%   如果尚未存在于 base workspace，调用 setup_ex18_sfw() 生成。
% ========================================================================
if ~evalin('base', 'exist(''cfg'', ''var'')')
    setup_ex18_sfw();
end
if ~evalin('base', 'exist(''sfw_meta'', ''var'')')
    setup_ex18_sfw();
end

% ---- 从 base workspace 读取全局配置 ----
cfg = evalin('base', 'cfg');
freq_hz = cfg.freq.hz(:);      % SFCW 各步频率轴 (Hz)，长度 = N
n_freq = numel(freq_hz);       % 频率点数
fs_hz = cfg.time.fs_hz;        % 仿真全局采样率 (Hz)
pri_s = cfg.time.pri_s;        % 每个频点的脉冲重复周期 (s)
step_count = n_freq;           % 步进数（= 频率点数）

% ========================================================================
% 步骤 4：准备输出目录
%   若 OutputDir 不存在则创建。
% ========================================================================
if exist(opts.OutputDir, 'dir') ~= 7
    mkdir(opts.OutputDir);
end

% ========================================================================
% 步骤 5：定义所有探头变量列表
%
%   探头变量命名：probe_<节点描述>
%   signal_type 取值：
%     'real'    — 实数信号（RF 通路上 / 实数混频产物 / 接收天线）
%     'complex' — 复数信号（IQ 解调后基带信号）
%
%   探头覆盖 SFCW GPR RF 前端链路的全路径：
%     SFW 源 → RF_In → Coupler → Attn → VGA → PA → RF_Out → TX → 信道 → RX → 下变频 → IF → IQ 解调
%
%   注意：RF 域中间节点（Coupler 主路出、Attenuator 后、VGA 后）
%         无法在 Simulink 中直接以实数信号观测，需要插入
%         RF Outport/Inport 转换器才能观测。
% ========================================================================
probe_vars = {
    % 信号源（Simulink 数字域，实信号）
    'probe_sfw_src',           'real';           % ▲ SFW 步进频率 burst 源
    % RF 主链路（RF 物理域 → Simulink 转换后，实信号）
    'probe_after_coupler_main','real';           % ▼ Coupler 主路直通输出
    'probe_tap_raw',           'real';           % ▼ Coupler 耦合支路原始输出
    'probe_before_attn',       'real';           % ◇ 衰减器输入端
    'probe_after_attn',        'real';           % ◇ 衰减器输出端
    'probe_before_vga',        'real';           % ◇ 可变增益放大器输入端
    'probe_after_vga',         'real';           % ◇ 可变增益放大器输出端
    'probe_before_pa',         'real';           % ◇ 功率放大器输入端
    'probe_after_pa',          'real';           % ◇ 功率放大器输出端
    % 发射 / GPR 信道 / 接收链路
    'probe_tx_radiated',       'real';           % ▶ 发射天线辐射输出
    'probe_after_gpr_channel', 'real';           % ▼ GPR 信道输出（含直耦+地表+杂波+目标）
    'probe_rx_antenna_raw',    'real';           % ◀ 接收天线原始输出
    % 耦合支路：上变频路径
    'probe_tap_mixer_raw',     'real';           % × 上变频混频器输出（含和频+差频+谐波）
    'probe_tap_up_bpf',        'real';           % ♢ 上变频带通滤波器后（上边带保留）
    % 接收支路：下变频路径
    'probe_rx_down_mixer_raw', 'real';           % × 下变频混频器输出（含 IF 差频+和频）
    'probe_rx_down_if',        'real';           % ♢ 中频带通滤波器后（190-210 MHz IF）
    % IQ 解调路径（复数信号！）
    'probe_iq_mixer_raw',      'complex';        % × IQ 复数混频器输出（双边复频谱）
    'probe_iq_baseband',       'complex';        % ♢ IQ 低通滤波器后复数基带
};

% 兼容旧版变量名（若模型尚未应用 patch_add_probes）
legacy_vars = {
    'rf_out_log',              'real';           % RF 发射输出日志
    'tap_up_log',              'real';           % 上变频支路日志
    'rx_down_if_log',          'real';           % 下变频 IF 日志
    'rx_iq_baseband_log',      'complex';        % IQ 基带复数日志
    'rx_antenna_log',          'real';           % 接收天线日志
    'rf_main_out_log',         'real';           % RF 主路输出日志
};

% ========================================================================
% 步骤 6：收集 workspace 中实际存在的探头变量
%   先扫描 probe_vars（新增探头），再扫描 legacy_vars（旧版兼容），
%   去重后存入 available 元胞数组。
%   每个元素：{variable_name, signal_type}
% ========================================================================
available = {};

% 6.1 扫描 probe_* 探头
for i = 1:size(probe_vars, 1)
    vname = probe_vars{i,1};
    % exist('varname', 'var') 检查 workspace 中是否存在该变量
    if evalin('base', sprintf('exist(''%s'', ''var'')', vname))
        available{end+1, 1} = vname;
        available{end, 2} = probe_vars{i,2};
    end
end

% 6.2 扫描 legacy *_log 探头（仅在 probe_vars 未覆盖时加入）
for i = 1:size(legacy_vars, 1)
    vname = legacy_vars{i,1};
    if evalin('base', sprintf('exist(''%s'', ''var'')', vname))
        % 避免重复添加
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

% 6.3 若一个探头都没有，提示用户先运行仿真
if isempty(available)
    fprintf(['No probe variables found in base workspace. ' ...
        'Run sim(''ex18_sfw_top'') first or set RunSimulation=true.\n']);
    return;
end

% 6.4 打印找到的探头列表
fprintf('ex18 Probe Spectrum Analysis\n');
fprintf('Found %d probe variables in workspace.\n', size(available, 1));
for i = 1:size(available, 1)
    fprintf('  %s (%s)\n', available{i,1}, available{i,2});
end

% ========================================================================
% 步骤 7：对每个探头执行 Step 分段 + FFT 宽频频谱分析
%   调用 ex18_step_spectrum_probe 做 SFCW 逐频点稳态幅相提取。
%   附加原始时域波形 data，供后续宽带 FFT 使用。
% ========================================================================
specs = {};
for i = 1:size(available, 1)
    vname = available{i,1};
    sig_type = available{i,2};

    % --- 7.1 从 base workspace 读取原始探头数据 ---
    raw = evalin('base', vname);

    % --- 7.2 统一化提取时轴和采样值 ---
    %   extract_uniform 可处理：
    %     - timeseries（Simulink 标准时间序列）
    %     - Structure With Time（ToWorkspace 块默认格式）
    %     - Dataset（Simulink 模型日志）
    %     - 纯数值数组
    [time_s, value] = extract_uniform(raw);

    if isempty(time_s) || isempty(value)
        fprintf('  WARN: %s is empty, skipping\n', vname);
        continue;
    end

    % --- 7.3 检测实际信号类型（覆盖预定义类型）---
    %   probe_vars 中的 signal_type 是预设分类，
    %   但如果信号实际为复数，应当走复数分析路径。
    if ~isreal(value)
        sig_type = 'complex';
    end

    % --- 7.4 根据变量名分类节点类型 ---
    %   不同节点有不同的频域特征：
    %     is_if       — 中频节点（190-210 MHz 局域谱）
    %     is_mixer    — 混频节点（宽频谱，含和频+差频+谐波）
    %     is_baseband — 基带节点（低频 IQ 解调输出）
    %   这些标签不对分析逻辑产生影响，仅用于信息标记。
    is_if = ~isempty(strfind(lower(vname), 'down_if'));
    is_mixer = ~isempty(strfind(lower(vname), 'mixer'));
    is_baseband = ~isempty(strfind(lower(vname), 'baseband')) ...
        || ~isempty(strfind(lower(vname), 'iq_log'));

    % --- 7.5 调用 Step 分段幅相提取函数 ---
    %   该函数对 SFCW 的每个频率 PRI 提取稳态段，
    %   输出 freq_hz（频率轴）、amp_db（幅度/dB）、
    %   phase_rad（相位/rad）、complex_response（复频响）。
    spec = ex18_step_spectrum_probe(raw, freq_hz, step_count, pri_s, fs_hz);
    spec.variable_name = vname;
    spec.signal_type = sig_type;
    spec.is_if = is_if;
    spec.is_mixer = is_mixer;
    spec.is_baseband = is_baseband;
    spec.time_s = time_s;     % 完整时轴（用于宽带 FFT）
    spec.value = value;       % 完整采样序列（用于宽带 FFT）

    specs{end+1} = spec;

    % --- 7.6 绘制该探头的单独频谱图 ---
    %   三行子图布局：
    %     Row 1 — 时域波形（实数或 I/Q 双曲线）
    %     Row 2 — 宽带 FFT 频谱（实数走单边谱，复数走 Step 谱）
    %     Row 3 — Step 分段频谱（幅频）或相位频响
    plot_individual_probe(spec, opts);
end

% ========================================================================
% 步骤 8：生成总体频域叠图
%   将所有探头的 Step 分段幅频曲线绘制在同一张图中，
%   方便对比各节点的频谱结构变化（频率搬移、滤波效果等）。
% ========================================================================
plot_frequency_overlay(specs, opts);

% ========================================================================
% 步骤 9：生成关键模块的传递谱 H(f)
%   计算 Y(f)/X(f) 并绘制增益 (dB) 和相位 (rad)。
%   覆盖：RF_Attn、RF_VGA、RF_PA、Tap_Up_BPF、
%         RX_Down_IF_BPF、IQ_LPF_Complex。
% ========================================================================
plot_module_transfers(specs, opts);

% ========================================================================
% 步骤 10：生成 IQ 解调双边复频谱图
%   对 IQ 基带或混频节点的复数信号做 fftshift FFT，
%   显示 ±20 MHz 范围的双边幅度谱，验证 IQ 解调架构正确性。
% ========================================================================
plot_iq_spectrum(specs, opts);

% ========================================================================
% 步骤 11：从 IQ 基带复数频响生成 A-scan
%   利用 ex18_step_spectrum_probe 提取的 complex_response，
%   执行 IFFT 得到时延域 A-scan，
%   左侧子图 x 轴为 Delay (ns)，
%   右侧子图 x 轴为 Depth (m)（使用土壤波速换算）。
%   并在图上叠加理论目标延迟和深度标记（绿色虚线）。
% ========================================================================
plot_ascan_from_probe(specs, opts);

fprintf('Analysis complete. Figures saved to: %s\n', opts.OutputDir);
end

% ========================================================================
% 内部函数 1：parse_probe_opts — 解析 Name-Value 参数
% ========================================================================
function opts = parse_probe_opts(varargin)
%PARSE_PROBE_OPTS  解析 ex18_probe_spectrum_analysis 的命令行选项。
%
%   使用 MATLAB inputParser 实现参数验证，
%   支持逻辑/数值/字符串类型的参数检查和默认值设定。

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

% ========================================================================
% 内部函数 2：run_preview_sim — 自动运行一次 SFCW 仿真
%
%   工作流程：
%     1. 确保模型未在内存中加载（避免旧版本残留）
%     2. 从磁盘加载 .slx 文件（预设包含探头块）
%     3. 将 InitFcn 设置为带 StepCount + SampleRate 的 setup 命令
%        — 这样在 sim() 启动时会自动调用正确的 setup 参数
%     4. 运行仿真
%        — 仿真过程中所有 ToWorkspace 探头块将数据写入 base workspace
%
%   关于 InitFcn 的说明：
%     模型文件本身预设的 InitFcn = 'setup_ex18_sfw;' 会覆盖 workspace
%     使用默认参数。本函数用 set_param 替换 InitFcn 为带参数版本，
%     确保仿真使用正确的 StepCount 和 SampleRate。
%
%   已知限制：
%     - 本函数在 local function 内通过 set_param + sim(model) 调用仿真，
%       ToWorkspace 块在本地函数上下文中的行为可能不同于命令行直接调用。
%       推荐用户手动执行 setup + load_system + set_param + sim。
% ========================================================================
function run_preview_sim(opts)
model = 'ex18_sfw_top';
model_file = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);

% 如果模型已在内存中打开，先强制关闭（丢弃未保存修改）
if bdIsLoaded(model)
    close_system(model, 1);
end
% 从磁盘文件加载模型（包含所有已添加的探头 ToWorkspace 块）
load_system(model_file);

% 构造带参数的 InitFcn 字符串
% 格式：setup_ex18_sfw('StepCount', 5, 'SampleRate', 2.0e9);
init_cmd = sprintf('setup_ex18_sfw(''StepCount'',%d,''SampleRate'',%.17g);', ...
    opts.StepCount, opts.SampleRate);
set_param(model, 'InitFcn', init_cmd);

% 启动仿真 — 此时 InitFcn 运行，设置 workspace，仿真执行
sim(model);
fprintf('Simulation complete.\n');
end

% ========================================================================
% 内部函数 3：extract_uniform — 统一化从各种数据格式中提取 (time, value)
%
%   支持的输入格式：
%     - timeseries                                  (Simulink 标准输出)
%     - struct with .time and .signals.values       (Structure With Time)
%     - Simulink.SimulationData.Dataset             (模型日志 Dataset)
%     - Simulink.SimulationData.Signal               (模型日志 Signal)
%     - 纯数值矩阵                                   (视为连续采样)
%
%   特殊处理 — 多帧数据：
%     Structure With Time 格式的数据维度为 [N_samples × N_channels × T_frames]。
%     squeeze 后可能变成 [N × T] 矩阵（每列一帧）。
%     本函数自动检测多帧情况（列数 > 1 或维数 ≥ 3），
%     取最后一帧（仿真结束时的帧，信号能量最完整），
%     用帧内采样点数重建线性时轴，避免截断。
% ========================================================================
function [time_s, value] = extract_uniform(raw)
% 判断输入格式并提取时轴和采样值
if isa(raw, 'timeseries')
    % 标准 Simulink 时间序列：直接取 Time 和 Data 属性
    time_s = raw.Time;
    value = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals')
    % Structure With Time 格式（ToWorkspace 块默认输出）
    time_s = raw.time;
    if isstruct(raw.signals) && isfield(raw.signals, 'values')
        value = raw.signals.values;   % 形状 [samples × channels × frames]
    else
        value = raw.signals;
    end
elseif isa(raw, 'Simulink.SimulationData.Dataset')
    % Dataset 格式：取第一个元素递归提取
    if raw.numElements < 1
        time_s = []; value = []; return;
    end
    [time_s, value] = extract_uniform(raw{1}.Values);
elseif isa(raw, 'Simulink.SimulationData.Signal')
    % Signal 格式：取 Values 递归提取
    [time_s, value] = extract_uniform(raw.Values);
elseif isnumeric(raw)
    % 纯数值数组：假设采样率未知，按时序线性排列
    value = raw(:);
    time_s = (0:numel(value)-1).';
else
    % 无法识别的格式，返回空
    time_s = []; value = [];
end

% ---- 后处理：去除多余维度，处理多帧数据 ----
if ~isempty(time_s)
    time_s = double(time_s(:));      % 确保时轴为列向量
    value = squeeze(double(value));  % 去除单维度（通道维）
    % value 的典型形状：
    %   - 单帧实数：   [N × 1]
    %   - 单帧复数：   无法直接判断（需 ~isreal）
    %   - 多帧：       [N × T]（经过 squeeze）
    %   - 多帧+通道：  [N × C × T]（经过 squeeze）

    sz = size(value);
    if ndims(value) >= 3 || (numel(sz) >= 2 && sz(2) > 1)
        % === 多帧处理 ===
        % 当信号具有多个时间帧时（如仿真中间帧 + 最终帧），
        % 取最后一帧作为主分析数据（信号最成熟、能量最完整）。
        value = value(:, :, end);   % 降维到最后一帧
        value = value(:);            % 压平为一维向量

        % 重建时轴：使用帧内采样点数（而非时间步数），
        % 采样间隔通过 time_s 的差值估算。
        if numel(value) > 1
            n = numel(value);
            % diff(time_s) 估算帧间采样间隔
            time_s = (0:n-1).' / max(diff(time_s(1:min(2,end))), eps);
        else
            % 极端情况：只有 1 个采样点
            n = min(numel(time_s), numel(value));
            value = value(1:n);
            time_s = time_s(1:n);
        end
    else
        % === 单帧处理 ===
        % 普通单帧信号：将时轴和采样值截取到相同长度
        value = value(:);
        n = min(numel(time_s), numel(value));
        time_s = time_s(1:n);
        value = value(1:n);
    end
end
end

% ========================================================================
% 内部函数 4：plot_individual_probe — 绘制单个探头的单独频谱图
%
%   图表布局（3 行 × 1 列）：
%     Subplot 1 — 时域波形
%       - 实数信号：蓝色实线
%       - 复数信号：蓝色实线（实部）+ 红色实线（虚部），加图例
%       - x 轴：时间 (ns)，限制在 0~200 ns
%
%     Subplot 2 — 频域谱
%       - 复数信号：Step 分段幅频曲线（蓝色）
%       - 实数信号：宽带单边 FFT 频谱（蓝色）
%         * Hann 窗加窗以抑制频谱泄漏
%         * NFFT 自动选择 ≥ 信号长度的最近 2 的幂
%         * 幅度归一化到 0 dB 峰值
%       - x 轴：频率 (MHz)，上限为 MaxFreqMHz
%
%     Subplot 3 — 补充谱
%       - 复数信号：Step 分段相频曲线（红色，度）
%       - 实数信号：Step 分段幅频曲线（绿色）
%       - x 轴：频率 (MHz)，上限为 MaxFreqMHz
%
%   FFT 安全保护：
%     - 信号采样点数 < 4 时跳过 FFT，显示提示文字
%     - mag_fft 和 f_fft 长度强制对齐，避免逻辑索引越界
% ========================================================================
function plot_individual_probe(spec, opts)
vname = spec.variable_name;
sig_type = spec.signal_type;
freq = spec.freq_hz;          % Step 分段提取的频率轴 (Hz)
amp = spec.amp_db;            % Step 分段提取的幅值 (dB)
phase = spec.phase_rad;       % Step 分段提取的相位 (rad)
time_s = spec.time_s;         % 完整时轴 (s)（用于宽带 FFT）
value = spec.value;           % 完整采样序列（用于宽带 FFT）
% 估算采样率：用时轴前几个点的间隔倒数近似 fs
fs_hz = 1 / max(diff(time_s(1:min(3, end))), eps);

max_f = opts.MaxFreqMHz * 1e6;  % 频谱显示上限频率 (Hz)
f_mask = freq <= max_f;          % Step 分段频谱的频率掩码

% ---- 创建 figure ----
fig = figure('Name', ['Probe: ' vname], ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 1000 750]);

% ========================================================================
% Subplot 1：时域波形
% ========================================================================
subplot(3, 1, 1);
% 实数部分 — 蓝色实线
plot(time_s * 1e9, real(value), 'b-', 'LineWidth', 0.7);
hold on;
% 如果信号是复数，叠绘虚部 — 红色实线
if ~isreal(value)
    plot(time_s * 1e9, imag(value), 'r-', 'LineWidth', 0.7);
    legend('Real (I)', 'Imag (Q)', 'Location', 'best');
end
grid on;
xlabel('Time (ns)');
ylabel('Amplitude');
title(sprintf('Time Domain: %s', vname));
xlim([0 min(200, time_s(end)*1e9)]);  % 最多显示 200 ns

% ========================================================================
% Subplot 2：频域谱（根据信号类型分两条路径）
% ========================================================================
if strcmp(sig_type, 'complex')
    % ================================================================
    % 复数信号：直接绘制 Step 分段提取的幅频曲线
    % Step 分段是针对 SFCW 最正确的窄带频域分析方法。
    % 不需要额外 FFT（信号本来就是复频响）。
    % ================================================================
    subplot(3, 1, 2);
    plot(freq / 1e6, amp, 'b-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Magnitude (dB)');
    title(sprintf('Step Spectrum: %s', vname));
    xlim([0 max_f/1e6]);

    % Subplot 3：相位频响（仅复数信号有）
    subplot(3, 1, 3);
    plot(freq / 1e6, phase * 180 / pi, 'r-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Phase (deg)');
    title(sprintf('Phase Response: %s', vname));
    xlim([0 max_f/1e6]);
else
    % ================================================================
    % 实数信号：宽带单边 FFT 分析
    %
    % 处理步骤：
    %   1. Hann 窗加窗 → 抑制旁瓣泄漏
    %   2. fft(·, NFFT) → NFFT 点 FFT（零填充提高频率分辨率）
    %   3. 取正频部分 (0:half-1) → 单边谱
    %   4. 幅度归一化到 0 dB 峰值 → log10 转换
    %   5. 频率轴截断到 MaxFreqMHz
    %
    % 为什么实数信号用 FFT 而非 Step 分段？
    %   实数信号是连续时间波形，不是 SFCW 逐频点的复包络。
    %   FFT 能捕获宽频成分：谐波、混频产物、镜频等。
    %   而 Step 分段更适合 SFCW 频率响应（IQ 解调后的复频响）。
    % ================================================================
    subplot(3, 1, 2);
    n = numel(value);
    if n < 4
        % 采样点太少无法做有意义的 FFT
        text(0.5, 0.5, 'Signal too short for FFT', 'Units', 'normalized', ...
            'HorizontalAlignment', 'center');
        axis([0 1 0 1]);
    else
        % --- FFT 参数计算 ---
        nfft = 2^nextpow2(min(n, 2^20));  % NFFT 为 2 的幂，最大 2^20
        % Hann 窗（时域加窗，抑制频谱泄漏）
        win = 0.5 - 0.5 * cos(2 * pi * (0:n-1).' / max(n-1, 1));
        % 时域数据加窗 → FFT
        spec_fft = fft(real(value(:)) .* win, nfft);

        % --- 单边频谱构建 ---
        half = floor(nfft/2) + 1;          % 正频 bin 数量（含 DC）
        f_fft = (0:half-1).' * fs_hz / nfft;  % 正频频率轴 (Hz)
        mag_fft = abs(spec_fft(1:half));    % 正频幅度值

        % --- 安全性：对齐 mag_fft 和 f_fft 长度 ---
        %   在某些数据格式下 mag_fft 可能与 f_fft 长度不一致
        %   （如 fft 输出矩阵或空信号），此处强制对齐。
        m = min(half, numel(mag_fft));
        mag_fft = mag_fft(1:m);

        % --- 归一化到 0 dB 峰值 ---
        mag_max = max(mag_fft);
        if mag_max > 0
            mag_fft_db = 20 * log10(mag_fft / max(mag_fft));
        else
            % 信号全为零或极弱 → 填充 -100 dB 避免 NaN
            mag_fft_db = -100 * ones(size(mag_fft));
        end

        % --- 清洗 NaN/Inf 并绘图 ---
        mag_safe = mag_fft_db;
        mag_safe(isnan(mag_safe) | isinf(mag_safe)) = -100;
        f_fft_safe = f_fft(1:m);           % 截断到与 mag 对齐的长度
        f_mask_fft = f_fft_safe <= max_f;  % 只显示 ≤ MaxFreqMHz 的成分
        plot(f_fft_safe(f_mask_fft) / 1e6, mag_safe(f_mask_fft), ...
            'b-', 'LineWidth', 0.8);
        grid on;
        xlabel('Frequency (MHz)');
        ylabel('Magnitude (dB)');
        title(sprintf('FFT Spectrum: %s', vname));
        xlim([0 max_f/1e6]);
    end

    % Subplot 3：Step 分段幅频曲线（作为补充谱）
    subplot(3, 1, 3);
    plot(freq / 1e6, amp, 'g-', 'LineWidth', 0.8);
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('Step Magnitude (dB)');
    title(sprintf('Step-Segmented Spectrum: %s', vname));
    xlim([0 max_f/1e6]);
end

% ---- 保存图片 ----
save_figure(fig, ['probe_' vname], opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

% ========================================================================
% 内部函数 5：plot_frequency_overlay — 所有探头频谱叠图
%
%   将每个探头的 Step 分段幅频曲线叠绘在同一 figure 中，
%   每种颜色对应一个探头节点。
%   x 轴：频率 (MHz)
%   y 轴：幅度 (dB)
%
%   用途：观察信号经过各级（放大/衰减/滤波/混频/解调）后的
%         频谱形态变化和频率搬移轨迹。
% ========================================================================
function plot_frequency_overlay(specs, opts)
if numel(specs) < 2
    return;  % 至少 2 个探头才有叠图意义
end

fig = figure('Name', 'Frequency Overlay', ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 1000 600]);

colors = lines(min(numel(specs), 20));  % 为每个探头分配不同颜色
hold on;
for i = 1:numel(specs)
    ci = mod(i-1, size(colors, 1)) + 1;  % 循环复用颜色
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

% ========================================================================
% 内部函数 6：plot_module_transfers — 关键模块传递谱 H(f)
%
%   对以下模块对计算 Y(f)/X(f) 并绘制增益和相位图：
%     RF_Attn        — 衰减器
%     RF_VGA         — 可变增益放大器
%     RF_PA          — 功率放大器
%     Tap_Up_BPF     — 上变频带通滤波器
%     RX_Down_IF_BPF — 下变频中频带通滤波器
%     IQ_LPF_Complex — IQ 解调低通滤波器
%
%   调用 ex18_module_transfer_spectrum 完成实际计算和绘图。
%   如果某个模块的输入端或输出端探头不存在，会跳过并打印提示。
% ========================================================================
function plot_module_transfers(specs, opts)
% 定义模块对：{输入端探头, 输出端探头, 模块名称}
module_pairs = {
    'probe_after_coupler_main', 'probe_after_attn',  'RF_Attn';          % 衰减器
    'probe_after_attn',         'probe_after_vga',   'RF_VGA';           % 可变增益放大器
    'probe_after_vga',          'probe_after_pa',    'RF_PA';            % 功率放大器
    'probe_tap_mixer_raw',      'probe_tap_up_bpf',  'Tap_Up_BPF';       % 上变频带通滤波器
    'probe_rx_down_mixer_raw',  'probe_rx_down_if',  'RX_Down_IF_BPF';   % 下变频中频带通滤波器
    'probe_iq_mixer_raw',       'probe_iq_baseband', 'IQ_LPF_Complex';   % IQ 解调低通滤波器
};

for p = 1:size(module_pairs, 1)
    in_name = module_pairs{p, 1};   % 输入端探头名
    out_name = module_pairs{p, 2};  % 输出端探头名
    mod_name = module_pairs{p, 3};  % 模块名称

    % 在 specs 列表中查找输入端和输出端探头
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

    % 缺少探头则跳过
    if isempty(in_idx) || isempty(out_idx)
        fprintf('  Skip transfer %s: missing probes\n', mod_name);
        continue;
    end

    % 从 base workspace 读取原始探头数据（用于传递谱计算）
    % ex18_module_transfer_spectrum 会内部调用 ex18_step_spectrum_probe
    % 提取每个频点的稳态响应，然后计算 H(f) = Y(f) / X(f)
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
    fprintf('  Transfer: %s (%s -> %s)\n', mod_name, in_name, out_name);
end
end

% ========================================================================
% 内部函数 7：plot_iq_spectrum — IQ 解调双边复频谱图
%
%   对 IQ 基带探头（probe_iq_baseband）或混频探头（probe_iq_mixer_raw）
%   的复数信号做 fftshift FFT，显示 -f_lim ~ +f_lim MHz 范围内的双边谱。
%
%   为什么需要双边频谱？
%     IQ 解调后的复数信号包含了 I 路和 Q 路的全部信息。
%     双边频谱可以清楚地区分正频和负频成分，
%     验证 IQ 不平衡、镜频抑制等指标。
%     而实数信号的单边谱只能显示正频。
%
%   默认显示范围：±20 MHz（f_lim = 20e6 Hz）
%   这是 IQ 解调后低通滤波器（10 MHz 截止）的理想通带区域。
% ========================================================================
function plot_iq_spectrum(specs, opts)
% 优先找 iq_baseband 探头，其次 iq_mixer_raw
iq_spec = [];
for i = 1:numel(specs)
    if ~isempty(strfind(specs{i}.variable_name, 'iq_baseband')) || ...
       ~isempty(strfind(specs{i}.variable_name, 'iq_mixer_raw'))
        iq_spec = specs{i};
        break;
    end
end

% 备选：如果没找到，使用最后一个探头（可能是唯一的 IQ 信号）
if isempty(iq_spec) && numel(specs) >= 1
    iq_spec = specs{end};
end
if isempty(iq_spec)
    return;
end

value = iq_spec.value;
% 若信号是实数则无法绘制双边谱（双边谱需要复数数据）
if isreal(value)
    return;
end

fs_hz = 1 / max(diff(iq_spec.time_s(1:min(3, end))), eps);
n = numel(value);
if n < 4
    fprintf('  SKIP IQ: %s has too few samples (%d)\n', iq_spec.variable_name, n);
    return;
end

% --- FFT 双边谱计算 ---
nfft = 2^nextpow2(min(n, 2^20));
% Hann 窗加窗
win = 0.5 - 0.5 * cos(2 * pi * (0:n-1).' / max(n-1, 1));
% fftshift 将零频移到中心 → 显示 -fs/2 ~ fs/2 范围
spec_fft = fftshift(fft(value(:) .* win, nfft));
% 双边频率轴：从 -nfft/2 到 nfft/2-1，步长 fs/nfft
f_fft = (-nfft/2:nfft/2-1).' * fs_hz / nfft;
% 幅度归一化并转为 dB
mag_raw = abs(spec_fft);

% --- 安全对齐 ---
m = min(nfft, numel(mag_raw));
mag_raw = mag_raw(1:m);
mag_db = 20 * log10(max(mag_raw / max(mag_raw + eps), eps));

% --- 截断显示范围：±f_lim ---
f_lim = 20e6;                          % 默认显示 ±20 MHz
f_fft_safe = f_fft(1:m);              % 截断到安全长度
f_mask = abs(f_fft_safe) <= f_lim;    % 选择 ±f_lim 内的频率点

% ---- 绘图 ----
fig = figure('Name', 'IQ Double-Sided Spectrum', ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 900 500]);

plot(f_fft_safe(f_mask) / 1e6, mag_db(f_mask), 'b-', 'LineWidth', 1);
grid on;
xlabel('Frequency (MHz)');
ylabel('Magnitude (dB)');
title(sprintf('IQ Double-Sided Spectrum: %s', iq_spec.variable_name));

save_figure(fig, 'iq_doublesided_spectrum', opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

% ========================================================================
% 内部函数 8：plot_ascan_from_probe — 从 IQ 基带复频响生成 A-scan
%
%   利用 ex18_step_spectrum_probe 提取的 complex_response，
%   执行 IFFT 得到时延域 A-scan。
%
%   图表布局（1 行 × 2 列）：
%     左侧：A-scan 时延域 — x 轴为 Delay (ns)
%     右侧：A-scan 深度域 — x 轴为 Depth (m)，使用土壤波速 v_soil 换算
%
%   处理步骤：
%     1. 提取 IQ 基带探头的 complex_response（SFCW 各频点复响应）
%     2. 填充无效频点（如果有 NaN）
%     3. Hann 窗加窗
%     4. IFFT（NFFT=4096，零填充提高时延分辨率）
%     5. 计算时延轴和深度轴
%     6. 在前 100 ns / 前 ~5 m 范围内绘图
%     7. 叠加理论目标延迟/深度标记（绿色虚线）
% ========================================================================
function plot_ascan_from_probe(specs, opts)
% 查找 IQ 基带探头数据
iq_probe = [];
for i = 1:numel(specs)
    if ~isempty(strfind(specs{i}.variable_name, 'iq_baseband'))
        iq_probe = specs{i};
        break;
    end
end

% 备选：若找不到基带探头，尝试混频输出探头
if isempty(iq_probe)
    for i = 1:numel(specs)
        if ~isempty(strfind(specs{i}.variable_name, 'iq_mixer_raw'))
            iq_probe = specs{i};
            break;
        end
    end
end

% 数据不足则跳过
if isempty(iq_probe) || isempty(iq_probe.complex_response)
    fprintf('  Skip A-scan: no IQ baseband probe data\n');
    return;
end

% ---- 提取复频响及相关参数 ----
freq_hz = iq_probe.freq_hz;          % SFCW 频率轴 (Hz)
response = iq_probe.complex_response;  % 对应复频响
valid = iq_probe.valid;               % 有效频点标记（true = 有效）

% 至少需要 10 个有效频点才能生成有意义的 A-scan
if nnz(valid) < 10
    fprintf('  Skip A-scan: too few valid frequency points (%d)\n', nnz(valid));
    return;
end

% 对无效频点做线性插值填充
bad = ~valid;
if any(bad)
    good_idx = find(valid);
    bad_idx = find(bad);
    if numel(good_idx) >= 2
        response(bad_idx) = interp1(good_idx, response(good_idx), ...
            bad_idx, 'linear', 'extrap');
    end
end

% ---- IFFT 生成 A-scan ----
df_hz = mean(diff(freq_hz));          % 频率步进 (Hz)
n_freq = numel(freq_hz);              % 频率点数
nfft = 4096;                           % IFFT 点数（零填充到 4096）
% Hann 窗：抑制 IFFT 旁瓣，提高时延域辨识度
window = 0.5 - 0.5 * cos(2 * pi * (0:n_freq-1).' / max(n_freq-1, 1));
% 加窗 → IFFT：复频响 → 时延域幅度
ascan = ifft(response .* window, nfft);

% ---- 时延轴计算 ----
% 每个 IFFT bin 对应时延 dt = 1 / (NFFT × df)
% 时延范围：0 ~ (NFFT-1) × dt
time_axis_s = (0:nfft-1).' / (nfft * df_hz);

% ---- 深度轴计算 ----
% depth = v_soil × delay / 2（单程路径，除以 2）
v_soil = 1e8;  % 默认波速 ~1e8 m/s（对应 eps_r ≈ 9）
try
    cfg = evalin('base', 'cfg');
    v_soil = cfg.gpr.soil_velocity_mps;
catch
end
depth_axis_m = v_soil * time_axis_s / 2;

% ---- 幅度计算 ----
amplitude = abs(ascan);                                 % 线性幅度
amp_db = 20 * log10(amplitude / max(amplitude + eps) + eps);  % dB 归一化

% ---- 创建 figure ----
fig = figure('Name', 'A-scan from Probe', ...
    'Visible', opts.Visible, 'Color', 'w', ...
    'Position', [100 100 1100 500]);

% ========================================================================
% 左侧子图：时延域 A-scan
%   x 轴 — Delay (ns)
%   y 轴 — 线性幅度（未经 dB 转换，保留目标峰原始高低）
%   显示范围：前 100 ns
% ========================================================================
subplot(1, 2, 1);
max_delay_ns = 100;
plot_mask = time_axis_s <= max_delay_ns * 1e-9;
plot(time_axis_s(plot_mask) * 1e9, amplitude(plot_mask), 'b-', 'LineWidth', 0.9);
grid on;
xlabel('Delay (ns)');
ylabel('Amplitude');
title('A-scan: Delay Domain');

% ========================================================================
% 右侧子图：深度域 A-scan
%   x 轴 — Depth (m)
%   y 轴 — 线性幅度
%   深度 = 土壤波速 × 时延 / 2
% ========================================================================
subplot(1, 2, 2);
plot(depth_axis_m(plot_mask), amplitude(plot_mask), 'r-', 'LineWidth', 0.9);
grid on;
xlabel('Depth (m)');
ylabel('Amplitude');
title(sprintf('A-scan: Depth Domain (v = %.3g m/s)', v_soil));

% ---- 叠加理论目标标记（如果 cfg 中有目标信息）----
try
    cfg = evalin('base', 'cfg');
    if isfield(cfg, 'gpr') && isfield(cfg.gpr, 'targets')
        % 在时延域图上标出各目标理论延迟（绿色虚线）
        subplot(1, 2, 1);
        hold on;
        for k = 1:numel(cfg.gpr.targets)
            d = cfg.gpr.targets(k).delay_s * 1e9;  % 理论延迟 (ns)
            yl = ylim;
            plot([d d], yl, 'g--', 'LineWidth', 1);
        end
        % 在深度域图上标出各目标理论深度（绿色虚线）
        subplot(1, 2, 2);
        hold on;
        for k = 1:numel(cfg.gpr.targets)
            depth = cfg.gpr.targets(k).depth_m;  % 理论深度 (m)
            yl = ylim;
            plot([depth depth], yl, 'g--', 'LineWidth', 1);
        end
    end
catch
    % 无法读取 cfg 时跳过目标标记
end

save_figure(fig, 'ascan_from_probe', opts);
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end

% ========================================================================
% 内部函数 9：save_figure — 统一保存 figure 到文件
%
%   文件名格式：OutputDir/ex18_<name>.png
%   分辨率：150 DPI
%   保存失败时降级使用 MATLAB 的 saveas。
% ========================================================================
function save_figure(fig, name, opts)
fname = fullfile(opts.OutputDir, ['ex18_' name '.png']);
try
    exportgraphics(fig, fname, 'Resolution', 150);
catch
    saveas(fig, fname);
end
fprintf('  Saved: %s\n', fname);
end

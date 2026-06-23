function cfg = setup_ex18_sfw(varargin)
%SETUP_EX18_SFW 准备 ex18 步进频率模型所需的工作区变量。
%
%   信号源遵循 PDF 中的步进频率定义：
%       f_i = f_0 + i * df
%       s_i(t) = C_i cos(2*pi*f_i*t + theta_i)
% cfg.gpr.scan_x_m —— 固定扫描位置，用于绘制 A-scan
% cfg.freq = struct() —— 频率计划
% cfg.time.fs_hz ——采样率
% cfg.front = struct() —— 衰减器、可调放大器、功率放大器和耦合器参数

work_dir = fileparts(mfilename('fullpath'));
if ~isempty(work_dir)
    addpath(work_dir);
    addpath(fullfile(work_dir, 'filterlib'));
    addpath(fullfile(work_dir, 'dialogs'));
end

cfg = default_cfg();
cfg = apply_user_opts(cfg, varargin{:});
cfg = derive_sfw(cfg);

[src_ts, freq_ts, meta] = make_sfw_burst( ...
    cfg.freq.hz, cfg.src.coef, ...
    'StepCount', cfg.time.step_count, ...
    'StartIndex', cfg.time.start_idx, ...
    'PRI', cfg.time.pri_s, ...
    'PulseWidth', cfg.time.pulse_s, ...
    'SampleRate', cfg.time.fs_hz, ...
    'UseAbsTime', cfg.src.use_abs_time, ...
    'PhaseContinuous', cfg.src.phase_continuous);

cfg.meta = meta;
cfg.range.res_m = meta.range_res_m;
cfg.range.unamb_m = meta.unamb_range_m;
cfg.time.duty = meta.duty;
cfg = derive_gpr_channel(cfg, meta);
cfg = derive_tap_mixer(cfg, meta);
cfg = derive_iq_demod(cfg, meta);
cfg = derive_rx_bpf_lna(cfg, meta);
cfg = derive_dsp_ascan(cfg, meta);

assign_sfw_vars(cfg, src_ts, freq_ts, meta);
assign_frontend_vars(cfg);
assign_gpr_vars(cfg, meta);
assign_tap_mixer_vars(cfg);
assign_iq_demod_vars(cfg);
assign_rx_bpf_lna_vars(cfg);
assign_dsp_ascan_vars(cfg);
try configure_ascan_display(cfg); catch; end
print_summary(cfg, meta);
end
%配置各部分参数
function cfg = default_cfg()
cfg = struct();

% 频率计划参数。
%   用户只需修改 f_start_hz（起始频率）、f_stop_hz（终止频率）、df_hz（步进频率）。
%   f_start_hz 和 f_stop_hz 同时作为实测频带边界写入 tap_mixer.input_band_hz。
cfg.freq = struct();
cfg.freq.f_start_hz = 20e6;
cfg.freq.f_stop_hz = 270e6;
cfg.freq.df_hz = 0.5e6;
cfg.freq.n = round((cfg.freq.f_stop_hz - cfg.freq.f_start_hz) / cfg.freq.df_hz) + 1;
% f0_hz / f1_hz / band_hz 是派生字段，由 derive_sfw 根据上述三个参数计算。
cfg.freq.f0_hz = cfg.freq.f_start_hz;

% 时域脉冲串和仿真采样参数。
cfg.time = struct();
% PRI，脉冲重复周期，也就是每个频点占用的时间长度，单位秒。
cfg.time.pri_s = 1e-6;
% 单个频点脉冲的有效脉宽，单位秒。等于 PRI 时，频点之间没有静默间隔。
cfg.time.pulse_s = cfg.time.pri_s;
% 生成时域波形和模型固定步长使用的采样率，单位 Hz。
cfg.time.fs_hz = 1e9;
% 从第几个频点开始生成预览波形。1 表示从第一个频点开始。
cfg.time.start_idx = 1;
% 本次仿真中实际生成多少个连续频点。默认等于频点总数。
cfg.time.step_count = cfg.freq.n;

% 信号源幅相参数。
cfg.src = struct();
% 每个频点的发射幅度 C_i。标量表示所有频点使用相同幅度。
cfg.src.amp = 1;
% 每个频点的初始相位 theta_i，单位 rad。标量表示所有频点使用相同相位。
cfg.src.phase_rad = 0;
% 是否使用全局绝对时间生成 cos(2*pi*f_i*t + theta_i)。相位连续模式开启时该项不参与源相位计算。
cfg.src.use_abs_time = true;
% 是否在频率步进边界保持 RF 相位连续。
cfg.src.phase_continuous = true;

% RF 前端链路参数。
cfg.front = struct();
% RF 网络参考阻抗，单位 Ohm。衰减器、可调放大器、功率放大器、耦合器和端接均使用该阻抗。
cfg.front.z0_ohm = 50;
% RF 衰减器衰减量，单位 dB。
cfg.front.attn_db = 10;
% 可调放大器电压增益，单位 dB。。
cfg.front.vga_gain_db = 0;
% 可调放大器噪声系数，单位 dB。写入 RF_VGA 的噪声参数。
cfg.front.vga_nf_db = 4;
% 功率放大器电压增益，单位 dB。默认 10 dB，使 VGA+PA 总增益接近原单级放大器。
cfg.front.pa_gain_db = 10;
% 功率放大器噪声系数，单位 dB。写入 RF_PA 的噪声参数。
cfg.front.pa_nf_db = 5;
% RF 耦合器耦合度，单位 dB。耦合支路幅度比例为 10^(-cfg.front.cpl_db/20)。
cfg.front.cpl_db = 6;
% RF 耦合器方向性，单位 dB。inf 表示理想隔离。
cfg.front.cpl_directivity_db = inf;
% RF 耦合器输入端到直通端的插入损耗，单位 dB。
cfg.front.cpl_insertion_loss_db = 3;
% RF 耦合器端口回波损耗，单位 dB。inf 表示理想匹配。
cfg.front.cpl_return_loss_db = inf;
% 接收链路 RX_BPF 带通滤波器阶数（Butterworth IIR）。
cfg.front.rx_bpf_order = 3;
% 接收链路 LNA 电压增益，单位线性倍数。10 = 20 dB，典型 LNA 增益。
cfg.front.rx_lna_gain = 10;
% 接收链路 LNA 噪声系数，单位 dB。
cfg.front.rx_lna_nf_db = 2;

% GPR 传播通道参数。使用均匀有损土壤、管道目标和弱杂波模型，
% 再转换成适配 ex18 时域 SFW burst 链路的 FIR 通道。
cfg.gpr = struct();
% 取该固定扫描位置，绘制A扫
cfg.gpr.scan_x_m = 0.5;
% 参考频率轴和扫描范围（用于频率归一化、幅度谱标记和杂波分布范围）。
cfg.gpr.ref_frequency_hz = linspace(20e6, 170e6, 501).';
cfg.gpr.ref_f_start_hz = 20e6;
cfg.gpr.ref_center_frequency_hz = 95e6;
cfg.gpr.ref_bandwidth_hz = 150e6;
cfg.gpr.ref_scan_x_limits_m = [-1.05, 1.05];
% 土壤相对介电常数。
cfg.gpr.soil_eps_r = 9.0;
% 土壤电导率，单位 S/m。
cfg.gpr.soil_sigma_s_per_m = 0.012;
% 发射和接收天线的横向间距，单位 m
cfg.gpr.txrx_spacing_m = 0.4;
% 天线离地高度，单位 m
cfg.gpr.antenna_height_m = 1.5;
% 直耦路径幅度。
cfg.gpr.direct_coupling_amplitude = 0.10;
% 直耦路径固定附加延迟，单位秒。
cfg.gpr.direct_extra_delay_s = 1.5e-9;
% 地表反射系数幅度。
cfg.gpr.surface_reflectivity = 0.75;
% 收发前端等效增益。
cfg.gpr.frontend_gain = 1.0;

% --- 管道目标参数（结构体数组，支持任意数量目标） ---
%   每个目标包含：center_x_m（横向位置）、depth_m（中心埋深）、radius_m（等效半径）、
%   reflectivity（复反射系数）、spreading_factor（几何扩散因子）、angular_taper（方向图指数）。
%   增加目标体只需向 targets 数组追加一行即可。
cfg.gpr.targets = struct();

i = 1;
cfg.gpr.targets(i).center_x_m       = 0.12;
cfg.gpr.targets(i).depth_m          = 0.9;
cfg.gpr.targets(i).radius_m         = 0.055;
cfg.gpr.targets(i).reflectivity     = 1.40 * exp(1i*0.35);
cfg.gpr.targets(i).spreading_factor = 1.25;
cfg.gpr.targets(i).angular_taper    = 0.55;

i = 2;
cfg.gpr.targets(i).center_x_m       = 0.12;
cfg.gpr.targets(i).depth_m          = 2.5;
cfg.gpr.targets(i).radius_m         = 0.04;
cfg.gpr.targets(i).reflectivity     = 10 * exp(1i*0.50);
cfg.gpr.targets(i).spreading_factor = 1.25;
cfg.gpr.targets(i).angular_taper    = 0.55;

% 弱随机点散射体数量。
cfg.gpr.clutter_count = 14;
% 弱随机点散射体深度范围，单位 m。
cfg.gpr.clutter_depth_range_m = [0.18, 1.20];
% 弱随机点散射体反射率幅度范围。
cfg.gpr.clutter_reflectivity_range = [0.008, 0.028];
% 弱随机点散射体随机种子。
cfg.gpr.clutter_random_seed = 11;
% 将频域土壤模型转换到时域 FIR 时使用的 FFT 点数。
cfg.gpr.fir_nfft = 4096;
% GPR_Channel 使用的 FIR 抽头数。留空时会按当前采样率和场景最大延迟自动计算，
% 避免高采样率下固定 256 点覆盖时间过短、截断目标回波。
cfg.gpr.fir_len = [];
% 自动 FIR 长度额外保护时间，用于覆盖前端等效群时延和窗截断余量。
cfg.gpr.fir_guard_s = 10e-9;
% 发射/接收天线方向，单位度，
cfg.gpr.rx_angle_deg = [0; 0];%[方位角; 俯仰角]。

% 耦合支路 200 MHz 本振上变频参数。
cfg.tap_mixer = struct();
% 上变频本振频率，单位 Hz。
cfg.tap_mixer.lo_hz = 200e6;
% 乘以 2 可补偿实数混频后上、下边带各占一半幅度的系数。
cfg.tap_mixer.lo_amp = 2;

% 混频器输入频带，也就是 RF_Tap_Out 中的原始 SFW 频带。
freq_stop_hz = cfg.freq.f0_hz + (cfg.freq.n - 1) * cfg.freq.df_hz;
cfg.tap_mixer.input_band_hz = [cfg.freq.f0_hz, freq_stop_hz];

% 实数混频会同时产生下边带和上边带：
%   lower sideband = LO - input_band = 30~180 MHz
%   upper sideband = LO + input_band = 220~370 MHz
% Tap_Up_BPF 的目标是保留上边带，滤掉下边带。
cfg.tap_mixer.lower_sideband_hz = cfg.tap_mixer.lo_hz - fliplr(cfg.tap_mixer.input_band_hz);
cfg.tap_mixer.upper_sideband_hz = cfg.tap_mixer.lo_hz + cfg.tap_mixer.input_band_hz;

% 上变频带通滤波器最终通带。guard 是保护带，避免滤波器过渡带切到
% 220~370 MHz 的有效上边带。当前实际通带为 210~380 MHz。
cfg.tap_mixer.up_bpf_guard_hz = 10e6;
cfg.tap_mixer.up_bpf_hz = cfg.tap_mixer.upper_sideband_hz + ...
    [-cfg.tap_mixer.up_bpf_guard_hz, cfg.tap_mixer.up_bpf_guard_hz];
% Tap_Up_BPF 的 FIR 阶数。阶数越高，过渡带越陡，但仿真越慢。
cfg.tap_mixer.up_bpf_order = 8192;

% 上变频支路与接收天线信号再次混频，保留约 200 MHz 的差频项。
% 通带需要窄于 200 MHz +/- 2*f_min 的实数混频和频项，避免低频点时
% 160 MHz / 240 MHz 等副产物进入 IF 观察点。
cfg.down_mixer = struct();
% 理想差频项：(LO + f) - f = LO，因此 IF 中心频率等于 200 MHz。
cfg.down_mixer.if_center_hz = cfg.tap_mixer.lo_hz;
% IF 带通半带宽。当前 10 MHz 表示最终通带为 190~210 MHz。
cfg.down_mixer.if_half_bw_hz = 10e6;
cfg.down_mixer.if_bpf_hz = cfg.down_mixer.if_center_hz + ...
    [-cfg.down_mixer.if_half_bw_hz, cfg.down_mixer.if_half_bw_hz];
% RX_Down_IF_BPF 的 FIR 阶数。阶数越高，和频项抑制越好，但仿真越慢。
cfg.down_mixer.if_bpf_order = 8192;

% I/Q 正交解调参数（取代单路最终混频器）。
% 输入是 RX_Down_IF_BPF 后的 190~210 MHz IF。
% I 路本振保持原相位（0°），Q 路本振偏移 -90°。
cfg.iq_demod = struct();
cfg.iq_demod.lo_hz = cfg.down_mixer.if_center_hz;
% 本振幅度。乘以 2 可补偿实数混频后差频、和频各占一半幅度的系数。
cfg.iq_demod.lo_amp = 2;
% I/Q 低通滤波器截止频率，单位 Hz。10 MHz 对应 IF 半带宽。
cfg.iq_demod.lpf_cutoff_hz = 10e6;
% I/Q 低通滤波器 FIR 阶数。
cfg.iq_demod.lpf_order = 1024;

end

function cfg = apply_user_opts(cfg, varargin)
parser = inputParser;
parser.addParameter('StepCount', cfg.time.step_count);
parser.addParameter('StartIndex', cfg.time.start_idx);
parser.addParameter('PRI', cfg.time.pri_s);
parser.addParameter('PulseWidth', cfg.time.pulse_s);
parser.addParameter('SampleRate', cfg.time.fs_hz);
parser.addParameter('UseAbsTime', cfg.src.use_abs_time);
parser.addParameter('PhaseContinuous', cfg.src.phase_continuous);
parser.parse(varargin{:});

cfg.time.step_count = parser.Results.StepCount;
cfg.time.start_idx = parser.Results.StartIndex;
cfg.time.pri_s = parser.Results.PRI;
cfg.time.pulse_s = parser.Results.PulseWidth;
cfg.time.fs_hz = parser.Results.SampleRate;
cfg.src.use_abs_time = parser.Results.UseAbsTime;
cfg.src.phase_continuous = parser.Results.PhaseContinuous;
end

function cfg = derive_sfw(cfg)
idx = (0:cfg.freq.n - 1).';
cfg.freq.hz = cfg.freq.f0_hz + idx * cfg.freq.df_hz;
cfg.freq.f1_hz = cfg.freq.hz(end);
cfg.freq.f_stop_hz = cfg.freq.f1_hz;
cfg.freq.band_hz = cfg.freq.f1_hz - cfg.freq.f0_hz;
cfg.src.coef = make_coef(cfg.src.amp, cfg.src.phase_rad, cfg.freq.n);
end

function cfg = derive_gpr_channel(cfg, meta)
c0 = 299792458;
cfg.gpr.center_frequency_hz = mean(cfg.freq.hz);
cfg.gpr.sfcw_frequency_hz = cfg.freq.hz;
cfg.gpr.soil_velocity_mps = 299792458 / sqrt(cfg.gpr.soil_eps_r);

direct_distance_m = hypot(cfg.gpr.txrx_spacing_m, 0.01);
surface_path_m = hypot(cfg.gpr.txrx_spacing_m, 2 * cfg.gpr.antenna_height_m);
x_tx_m = cfg.gpr.scan_x_m - cfg.gpr.txrx_spacing_m / 2;
x_rx_m = cfg.gpr.scan_x_m + cfg.gpr.txrx_spacing_m / 2;

% --- 对每个目标计算双程路径和时延（含空气程）---
c0 = 299792458;
n_targets = numel(cfg.gpr.targets);
for k = 1:n_targets
    t = cfg.gpr.targets(k);
    % Tx->目标中心的水平距离
    hx_tx_m = abs(x_tx_m - t.center_x_m);
    hx_rx_m = abs(x_rx_m - t.center_x_m);
    % 土壤内斜距：从地表入射点到目标中心（近似直线，折射忽略）
    soil_tx_m = hypot(hx_tx_m, t.depth_m);
    soil_rx_m = hypot(hx_rx_m, t.depth_m);
    % 减去管道半径（近似）
    soil_tx_m = max(soil_tx_m - t.radius_m, 0);
    soil_rx_m = max(soil_rx_m - t.radius_m, 0);
    % 空气程：天线高度往返（垂直近似），双程 = 2 * antenna_height_m
    air_tx_m = cfg.gpr.antenna_height_m;
    air_rx_m = cfg.gpr.antenna_height_m;
    % 总时延 = 空气程/c0 + 土壤程/soil_velocity
    delay_s = (air_tx_m + air_rx_m) / c0 + ...
              (soil_tx_m + soil_rx_m) / cfg.gpr.soil_velocity_mps;
    path_m = air_tx_m + air_rx_m + soil_tx_m + soil_rx_m; % 仅用于记录总几何长度
    cfg.gpr.targets(k).path_m = path_m;
    cfg.gpr.targets(k).delay_s = delay_s;
    cfg.gpr.targets(k).delay_samples = delay_samples( ...
        cfg.gpr.targets(k).delay_s, meta.sample_s);
end

% 向后兼容：主目标（第一个）的标量字段，供 Simulink 和旧代码使用。
cfg.gpr.target_path_m    = cfg.gpr.targets(1).path_m;
cfg.gpr.target_delay_s   = cfg.gpr.targets(1).delay_s;
cfg.gpr.target_delay_samples = cfg.gpr.targets(1).delay_samples;

cfg.gpr.direct_delay_s = cfg.gpr.direct_extra_delay_s + direct_distance_m / c0;
cfg.gpr.surface_delay_s = surface_path_m / c0;
cfg.gpr.direct_delay_samples = delay_samples(cfg.gpr.direct_delay_s, meta.sample_s);
cfg.gpr.surface_delay_samples = delay_samples(cfg.gpr.surface_delay_s, meta.sample_s);
cfg.gpr.fir_len = resolve_gpr_fir_len(cfg.gpr, meta.sample_s);

[cfg.gpr.soil_fir, cfg.gpr.soil_model] = ex18_make_soil_fir(cfg.gpr, meta.sample_s);
cfg.gpr.direct_gain = cfg.gpr.soil_model.direct_gain;
cfg.gpr.surface_gain = cfg.gpr.soil_model.surface_gain;
cfg.gpr.target_gain = cfg.gpr.soil_model.target_gain;

end

function cfg = derive_tap_mixer(cfg, meta)
[num, den] = ex18_design_fir_bandpass( ...
    cfg.tap_mixer.up_bpf_order, cfg.tap_mixer.up_bpf_hz, meta.fs_hz, ...
    'setup_ex18_sfw:BadTapUpBPF');
cfg.tap_mixer.up_bpf_num = num;
cfg.tap_mixer.up_bpf_den = den;

[num, den] = ex18_design_fir_bandpass( ...
    cfg.down_mixer.if_bpf_order, cfg.down_mixer.if_bpf_hz, meta.fs_hz, ...
    'setup_ex18_sfw:BadDownIFBPF');
cfg.down_mixer.if_bpf_num = num;
cfg.down_mixer.if_bpf_den = den;
end

function n = delay_samples(delay_s, sample_s)
n = max(0, round(delay_s / sample_s));
end

function cfg = derive_iq_demod(cfg, meta)
[num, den] = ex18_design_fir_lowpass(cfg.iq_demod.lpf_order, cfg.iq_demod.lpf_cutoff_hz, meta.fs_hz);
cfg.iq_demod.lpf_num = num;
cfg.iq_demod.lpf_den = den;
end

function cfg = derive_rx_bpf_lna(cfg, meta)
% 设计接收链路预选带通滤波器（Butterworth IIR）。
bpf_order = cfg.front.rx_bpf_order;
f_pass = [cfg.freq.f_start_hz, cfg.freq.f_stop_hz];
f_nyq = meta.fs_hz / 2;
[b, a] = butter(bpf_order, f_pass / f_nyq, 'bandpass');
cfg.front.rx_bpf_num = b;
cfg.front.rx_bpf_den = a;
end

function cfg = derive_dsp_ascan(cfg, meta)
% 为 DSP A-scan 管线准备预处理数据：Hann 窗向量和背景频响。
%   这些数据是常量，供 Simulink 中 Buffer→Window→BGS→IFFT→|·| 管线使用。

n_freq = numel(cfg.freq.hz);

% Hann 窗（与 make_ascan 保持一致，抑制 IFFT 旁瓣）
cfg.dsp_ascan = struct();
cfg.dsp_ascan.window = 0.5 - 0.5 * cos(2 * pi * (0:n_freq - 1).' / max(n_freq - 1, 1));

% IFFT 点数（含零填充），与 ex18_make_ascan 默认 NFFT=4096 一致
cfg.dsp_ascan.nfft = 4096;

% IFFT 每 bin 对应时延步长，单位 ns：dt = 1 / (n_freq * df)
cfg.dsp_ascan.delay_step_ns = 1 / (n_freq * cfg.freq.df_hz) * 1e9;

% A-scan 横轴模式：'delay_ns' 显示延迟 (ns)，'depth_m' 显示深度 (m)
cfg.dsp_ascan.xaxis_mode = 'delay_ns';
% 当 xaxis_mode = 'depth_m' 时，使用 cfg.gpr.soil_velocity_mps 换算深度

% 每 PRI 采样点数 = 采样率 × PRI
cfg.dsp_ascan.samples_per_pri = round(meta.fs_hz * meta.pri_s);

end

function fir_len = resolve_gpr_fir_len(gpr, sample_s)
if ~isempty(gpr.fir_len)
    fir_len = max(1, round(gpr.fir_len));
    return;
end

max_clutter_depth_m = max(gpr.clutter_depth_range_m(:));
max_clutter_delay_s = 2 * max_clutter_depth_m / gpr.soil_velocity_mps;
all_target_delays = [gpr.targets.delay_s];
required_delay_s = max([gpr.direct_delay_s, gpr.surface_delay_s, ...
    all_target_delays, max_clutter_delay_s]) + gpr.fir_guard_s;
required_samples = ceil(required_delay_s / sample_s) + 1;

fir_len = 2 ^ nextpow2(max(64, required_samples));
if fir_len >= gpr.fir_nfft
    fir_len = gpr.fir_nfft - 1;
end
end

function coef = make_coef(amp, phase_rad, n)
amp = expand_value(amp, n, 'amp');
phase_rad = expand_value(phase_rad, n, 'phase_rad');
coef = amp(:) .* exp(1i * phase_rad(:));
end

function value = expand_value(value, n, name)
value = value(:);
if isscalar(value)
    value = repmat(value, n, 1);
elseif numel(value) ~= n
    error('setup_ex18_sfw:BadVector', ...
        '%s must be a scalar or a vector with %d elements.', name, n);
end
end

function assign_sfw_vars(cfg, src_ts, freq_ts, meta)
assignin('base', 'cfg', cfg);
assignin('base', 'sfw_freq_hz', cfg.freq.hz);
assignin('base', 'sfw_df_hz', cfg.freq.df_hz);
assignin('base', 'sfw_coef', cfg.src.coef);
assignin('base', 'sfw_src_ts', src_ts);
assignin('base', 'sfw_freq_ts', freq_ts);
assignin('base', 'sfw_meta', meta);
assignin('base', 'sfw_fs_hz', meta.fs_hz);
assignin('base', 'sfw_sample_s', meta.sample_s);
assignin('base', 'sfw_pri_s', meta.pri_s);
assignin('base', 'sfw_pulse_s', meta.pulse_s);
assignin('base', 'sfw_duty', meta.duty);
assignin('base', 'sfw_stop_s', meta.stop_s);
assignin('base', 'sfw_range_res_m', meta.range_res_m);
assignin('base', 'sfw_unamb_range_m', meta.unamb_range_m);
end

function assign_frontend_vars(cfg)
rf_vga_s = make_two_port_gain_s(cfg.front.vga_gain_db);
rf_pa_s = make_two_port_gain_s(cfg.front.pa_gain_db);
rf_cpl_s = make_rf_coupler_s(cfg.front);

assignin('base', 'rf_z0_ohm', cfg.front.z0_ohm);
assignin('base', 'rf_attn_db', cfg.front.attn_db);
assignin('base', 'rf_vga_s', rf_vga_s);
assignin('base', 'rf_vga_freq_hz', cfg.freq.f0_hz);
assignin('base', 'rf_vga_gain_db', cfg.front.vga_gain_db);
assignin('base', 'rf_vga_nf_db', cfg.front.vga_nf_db);
assignin('base', 'rf_pa_s', rf_pa_s);
assignin('base', 'rf_pa_freq_hz', cfg.freq.f0_hz);
assignin('base', 'rf_pa_gain_db', cfg.front.pa_gain_db);
assignin('base', 'rf_pa_nf_db', cfg.front.pa_nf_db);
assignin('base', 'rf_cpl_db', cfg.front.cpl_db);
assignin('base', 'rf_cpl_directivity_db', cfg.front.cpl_directivity_db);
assignin('base', 'rf_cpl_insertion_loss_db', cfg.front.cpl_insertion_loss_db);
assignin('base', 'rf_cpl_return_loss_db', cfg.front.cpl_return_loss_db);
assignin('base', 'rf_cpl_s', rf_cpl_s);
assignin('base', 'rf_cpl_freq_hz', mean(cfg.freq.hz));
end

function s = make_two_port_gain_s(gain_db)
gain = 10^(gain_db / 20);
s = [0 0; gain 0];
end

function rf_cpl_s = make_rf_coupler_s(front)
% 生成前向取样耦合器的四端口 S 参数。
% 端口约定：1 为输入，2 为主路直通，3 为隔离端，4 为耦合支路。
coupled = db_to_mag(front.cpl_db);
isolated = db_to_mag(front.cpl_db + front.cpl_directivity_db);
returned = db_to_mag(front.cpl_return_loss_db);
through = db_to_mag(front.cpl_insertion_loss_db);

max_through = sqrt(max(0, 1 - coupled^2 - isolated^2 - returned^2));
if through > max_through
    warning('setup_ex18_sfw:CouplerNotPassive', ...
        ['耦合器 S 参数不满足无源条件，已将直通幅度 %.4g 调整为 %.4g。' ...
        '请增大 cfg.front.cpl_insertion_loss_db 或减小 cfg.front.cpl_db。'], ...
        through, max_through);
    through = max_through;
end

rf_cpl_s = zeros(4);
rf_cpl_s(1, 1) = returned;
rf_cpl_s(2, 1) = through;
rf_cpl_s(3, 1) = isolated;
rf_cpl_s(4, 1) = coupled;
end

function mag = db_to_mag(db_value)
if isinf(db_value)
    mag = 0;
else
    mag = 10^(-db_value / 20);%耦合公式
end
end

function assign_gpr_vars(cfg, meta)
assignin('base', 'gpr_soil_eps_r', cfg.gpr.soil_eps_r);
assignin('base', 'gpr_soil_sigma_s_per_m', cfg.gpr.soil_sigma_s_per_m);
assignin('base', 'gpr_soil_velocity_mps', cfg.gpr.soil_velocity_mps);
assignin('base', 'gpr_scan_x_m', cfg.gpr.scan_x_m);
assignin('base', 'gpr_soil_fir', cfg.gpr.soil_fir);
assignin('base', 'gpr_soil_model', cfg.gpr.soil_model);
assignin('base', 'gpr_channel_freq_hz', cfg.gpr.soil_model.frequency_hz);
assignin('base', 'gpr_channel_response', cfg.gpr.soil_model.response);
assignin('base', 'gpr_direct_delay_samples', cfg.gpr.direct_delay_samples);
assignin('base', 'gpr_surface_delay_samples', cfg.gpr.surface_delay_samples);
assignin('base', 'gpr_target_delay_samples', cfg.gpr.target_delay_samples);
assignin('base', 'gpr_direct_gain', cfg.gpr.direct_gain);
assignin('base', 'gpr_surface_gain', cfg.gpr.surface_gain);
assignin('base', 'gpr_target_gain', cfg.gpr.target_gain);
assignin('base', 'gpr_rx_angle_deg', cfg.gpr.rx_angle_deg);
end

function assign_tap_mixer_vars(cfg)
assignin('base', 'tap_lo_hz', cfg.tap_mixer.lo_hz);
assignin('base', 'tap_lo_amp', cfg.tap_mixer.lo_amp);
assignin('base', 'tap_input_band_hz', cfg.tap_mixer.input_band_hz);
assignin('base', 'tap_lower_sideband_hz', cfg.tap_mixer.lower_sideband_hz);
assignin('base', 'tap_upper_sideband_hz', cfg.tap_mixer.upper_sideband_hz);
assignin('base', 'tap_up_bpf_guard_hz', cfg.tap_mixer.up_bpf_guard_hz);
assignin('base', 'tap_up_bpf_hz', cfg.tap_mixer.up_bpf_hz);
assignin('base', 'tap_up_bpf_num', cfg.tap_mixer.up_bpf_num);
assignin('base', 'tap_up_bpf_den', cfg.tap_mixer.up_bpf_den);
assignin('base', 'tap_up_bpf_order', cfg.tap_mixer.up_bpf_order);
assignin('base', 'rx_down_if_center_hz', cfg.down_mixer.if_center_hz);
assignin('base', 'rx_down_if_half_bw_hz', cfg.down_mixer.if_half_bw_hz);
assignin('base', 'rx_down_if_bpf_hz', cfg.down_mixer.if_bpf_hz);
assignin('base', 'rx_down_if_bpf_num', cfg.down_mixer.if_bpf_num);
assignin('base', 'rx_down_if_bpf_den', cfg.down_mixer.if_bpf_den);
assignin('base', 'rx_down_if_bpf_order', cfg.down_mixer.if_bpf_order);
end

function assign_iq_demod_vars(cfg)
assignin('base', 'iq_lo_hz', cfg.iq_demod.lo_hz);
assignin('base', 'iq_lo_amp', cfg.iq_demod.lo_amp);
assignin('base', 'iq_lpf_cutoff_hz', cfg.iq_demod.lpf_cutoff_hz);
assignin('base', 'iq_lpf_num', cfg.iq_demod.lpf_num);
assignin('base', 'iq_lpf_order', cfg.iq_demod.lpf_order);
end

function assign_rx_bpf_lna_vars(cfg)
assignin('base', 'rx_bpf_num', cfg.front.rx_bpf_num);
assignin('base', 'rx_bpf_den', cfg.front.rx_bpf_den);
assignin('base', 'rx_lna_gain', cfg.front.rx_lna_gain);
assignin('base', 'rx_lna_nf_db', cfg.front.rx_lna_nf_db);
end

function assign_dsp_ascan_vars(cfg)
% 将 DSP A-scan 管线需要的常量写入 base workspace。
%   dsp_ascan_window     — N 点 Hann 窗向量
%   dsp_ascan_nfft       — IFFT 点数 (4096)
%   dsp_ascan_delay_step_ns — 每 bin 对应的时延步长 (ns)
%   dsp_ascan_xaxis_mode — 横轴模式：'delay_ns' 或 'depth_m'
%   dsp_samples_per_pri  — 每 PRI 的采样点数（用于下采样）

assignin('base', 'dsp_ascan_window', cfg.dsp_ascan.window);
assignin('base', 'dsp_ascan_nfft', cfg.dsp_ascan.nfft);
assignin('base', 'dsp_ascan_delay_step_ns', cfg.dsp_ascan.delay_step_ns);
assignin('base', 'dsp_ascan_xaxis_mode', cfg.dsp_ascan.xaxis_mode);
assignin('base', 'dsp_samples_per_pri', cfg.dsp_ascan.samples_per_pri);

% 背景频响（直耦+地表+杂波，不含目标），取自土壤模型的分量
if isfield(cfg.gpr, 'soil_model') && ...
   isfield(cfg.gpr.soil_model, 'sfcw_parts') && ...
   isfield(cfg.gpr.soil_model.sfcw_parts, 'background_response')
    bg = cfg.gpr.soil_model.sfcw_parts.background_response;
    assignin('base', 'dsp_background_response', bg(:));
end
end

function print_summary(cfg, meta)
fprintf('ex18 SFW workspace ready.\n');
fprintf('Freq: %.3f-%.3f MHz, n = %d, df = %.3f MHz, bandwidth = %.3f MHz\n', ...
    cfg.freq.f_start_hz / 1e6, cfg.freq.f_stop_hz / 1e6, ...
    cfg.freq.n, cfg.freq.df_hz / 1e6, cfg.freq.band_hz / 1e6);
fprintf('Time: PRI = %.6g s, pulse = %.6g s, duty = %.1f%%, Fs = %.3f MHz\n', ...
    meta.pri_s, meta.pulse_s, 100 * meta.duty, meta.fs_hz / 1e6);
fprintf('Source phase continuous: %d\n', meta.phase_continuous);
fprintf('Range: dR = %.3f m, Ru = %.3f m\n', ...
    cfg.range.res_m, cfg.range.unamb_m);
fprintf('RF main chain: Attn = %.3g dB, VGA = %.3g dB, PA = %.3g dB\n', ...
    cfg.front.attn_db, cfg.front.vga_gain_db, cfg.front.pa_gain_db);
fprintf('GPR channel: soil eps_r = %.2f, sigma = %.4g S/m\n', ...
    cfg.gpr.soil_eps_r, cfg.gpr.soil_sigma_s_per_m);
for k = 1:numel(cfg.gpr.targets)
    fprintf('  Target %d: x=%.2f m, depth=%.2f m, r=%.3f m, delay=%.3g ns (%d samples)\n', ...
        k, cfg.gpr.targets(k).center_x_m, cfg.gpr.targets(k).depth_m, ...
        cfg.gpr.targets(k).radius_m, ...
        cfg.gpr.targets(k).delay_s * 1e9, cfg.gpr.targets(k).delay_samples);
end
fprintf('GPR FIR: nfft = %d, length = %d taps (%.3g ns)\n', ...
    cfg.gpr.fir_nfft, cfg.gpr.fir_len, cfg.gpr.fir_len * meta.sample_s * 1e9);
fprintf('RX_BPF: Butterworth order %d, passband %.3f-%.3f MHz\n', ...
    cfg.front.rx_bpf_order, ...
    cfg.freq.f_start_hz / 1e6, cfg.freq.f_stop_hz / 1e6);
fprintf('RX_LNA: gain = %.1f (%.1f dB), NF = %.1f dB\n', ...
    cfg.front.rx_lna_gain, 20*log10(cfg.front.rx_lna_gain), ...
    cfg.front.rx_lna_nf_db);
fprintf('Tap mixer input band: %.3f-%.3f MHz, LO = %.3f MHz\n', ...
    cfg.tap_mixer.input_band_hz(1) / 1e6, cfg.tap_mixer.input_band_hz(2) / 1e6, ...
    cfg.tap_mixer.lo_hz / 1e6);
fprintf('Tap mixer sidebands: lower = %.3f-%.3f MHz, upper = %.3f-%.3f MHz\n', ...
    cfg.tap_mixer.lower_sideband_hz(1) / 1e6, cfg.tap_mixer.lower_sideband_hz(2) / 1e6, ...
    cfg.tap_mixer.upper_sideband_hz(1) / 1e6, cfg.tap_mixer.upper_sideband_hz(2) / 1e6);
fprintf('Tap_Up_BPF: %.3f-%.3f MHz (guard = %.3f MHz, order = %d)\n', ...
    cfg.tap_mixer.up_bpf_hz(1) / 1e6, cfg.tap_mixer.up_bpf_hz(2) / 1e6, ...
    cfg.tap_mixer.up_bpf_guard_hz / 1e6, cfg.tap_mixer.up_bpf_order);
fprintf('RX_Down_IF_BPF: center = %.3f MHz, half BW = %.3f MHz, passband = %.3f-%.3f MHz, order = %d\n', ...
    cfg.down_mixer.if_center_hz / 1e6, cfg.down_mixer.if_half_bw_hz / 1e6, ...
    cfg.down_mixer.if_bpf_hz(1) / 1e6, cfg.down_mixer.if_bpf_hz(2) / 1e6, ...
    cfg.down_mixer.if_bpf_order);
fprintf('IQ demod: LO = %.3f MHz, LPF cutoff = %.3f MHz, order = %d\n', ...
    cfg.iq_demod.lo_hz / 1e6, cfg.iq_demod.lpf_cutoff_hz / 1e6, ...
    cfg.iq_demod.lpf_order);
end

function configure_ascan_display(cfg)
%CONFIGURE_ASCAN_DISPLAY  Set ArrayPlot parameters for A-scan display.
%
%   Configures the DSP ArrayPlot block in the model (if it exists) to show
%   the correct x-axis:
%     - SampleIncrement = dsp_ascan_delay_step_ns (literal numeric value)
%   - XLabel = 'Delay (ns)' or 'Depth (m)' based on xaxis_mode

model = 'ex18_sfw_top';
if ~bdIsLoaded(model)
    return;
end

% Look for ArrayPlot blocks in the model
array_plots = find_system(model, 'SearchDepth', 2, 'BlockType', 'ArrayPlot');

if isempty(array_plots)
    % Model may not be loaded; set variables for manual configuration
    return;
end

delay_step_ns = cfg.dsp_ascan.delay_step_ns;

for k = 1:numel(array_plots)
    full_path = array_plots{k};

    % Set SampleIncrement to the literal numeric value
    try
        set_param(full_path, 'SampleIncrement', num2str(delay_step_ns));
    catch
    end

    % Set XLabel based on mode
    switch cfg.dsp_ascan.xaxis_mode
        case 'depth_m'
            try
                set_param(full_path, 'XLabel', 'Depth (m)');
            catch
            end
        otherwise
            try
                set_param(full_path, 'XLabel', 'Delay (ns)');
            catch
            end
    end

    % Set YLabel
    try
        set_param(full_path, 'YLabel', 'Amplitude');
    catch
    end

    % Set Title
    try
        set_param(full_path, 'Title', sprintf('A-scan (dR=%.3f m, Ru=%.3f m)', ...
            cfg.range.res_m, cfg.range.unamb_m));
    catch
    end
end
end

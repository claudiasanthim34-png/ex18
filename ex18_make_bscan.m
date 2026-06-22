function results = ex18_make_bscan(varargin)
%EX18_MAKE_BSCAN 从 ex18 解析土壤模型生成 B-scan 图像。
%   B-scan = 不同天线位置下多个 A-scan 的堆叠。
%   使用与 ex18_make_ascan 相同的解析土壤/杂波/管道模型，
%   不运行 Simulink（快速模型引用路径）。
%
%   results = ex18_make_bscan()
%       默认运行：121 个扫描位置，全部 501 个 SFCW 频点。
%
%   results = ex18_make_bscan('NScans', 61, 'NFFT', 2048)
%       减少扫描位置和 IFFT 点数，用于快速预览。
%
%   输出：将 B-scan PNG 和 MAT 保存到 ex18/output/。

work_dir = fileparts(mfilename('fullpath'));
addpath(work_dir);

opts = parse_bscan_opts(varargin{:});
opts.Timestamp = datestr(now, 'yyyymmdd_HHMMSS');
ensure_workspace();

cfg = evalin('base', 'cfg');
gpr = cfg.gpr;

% --- 定义扫描位置（横向天线移动轨迹） ---
scan_x_m = linspace(gpr.ref_scan_x_limits_m(1), ...
                    gpr.ref_scan_x_limits_m(2), opts.NScans);
freq_hz = cfg.freq.hz(:);
n_freq = numel(freq_hz);

% --- 预计算电磁状态（所有位置共用） ---
state = build_bscan_state(gpr, freq_hz);
state.frontend = frontend_response_bscan(freq_hz, gpr);

% --- 采集所有扫描位置的频率响应 ---
response_all = complex(nan(n_freq, opts.NScans));
background_all = complex(nan(n_freq, opts.NScans));

fprintf('计算 B-scan: %d 个位置 x %d 个频点...\n', opts.NScans, n_freq);
for k = 1:opts.NScans
    [ch, parts] = channel_response_bscan(scan_x_m(k), state);
    response_all(:, k) = ch;
    background_all(:, k) = parts.direct + parts.surface + parts.clutter;
    if mod(k, 20) == 0, fprintf('  已完成 %d/%d\n', k, opts.NScans); end
end
fprintf('  完成.\n');

% --- 背景扣除 ---
if strcmp(opts.BackgroundMode, 'model')
    % 估算总响应与背景之间的复比例系数，
    % 然后减去缩放后的背景，以突出目标信号。
    response_bgsub = complex(nan(n_freq, opts.NScans));
    for k = 1:opts.NScans
        scale = (background_all(:, k)' * response_all(:, k)) / ...
                max(background_all(:, k)' * background_all(:, k), eps);
        response_bgsub(:, k) = response_all(:, k) - scale * background_all(:, k);
    end
else
    response_bgsub = response_all;
end

% --- IFFT 到时域（每个位置对应一个 A-scan） ---
nfft = opts.NFFT;
dt_ns = 1 / (nfft * cfg.freq.df_hz) * 1e9;
time_axis_ns = (0:nfft - 1)' * dt_ns;
time_profile = zeros(nfft, opts.NScans);

for k = 1:opts.NScans
    spec = response_bgsub(:, k);
    % Hann 窗，抑制频谱泄露
    w = hann(n_freq);
    spec_win = spec(:) .* w(:);
    % 补零后 IFFT（插值时域）
    spec_pad = [spec_win; zeros(nfft - n_freq, 1)];
    time_profile(:, k) = ifft(spec_pad, nfft);
end

% --- 收集结果 ---
results = struct();
results.scan_x_m = scan_x_m;
results.time_axis_ns = time_axis_ns;
results.time_profile = time_profile;
results.response_all = response_all;
results.response_bgsub = response_bgsub;
results.background_all = background_all;
results.freq_hz = freq_hz;
results.opts = opts;

% --- 绘制 B-scan ---
plot_bscan(results, opts);

% --- 保存 ---
out_dir = fullfile(work_dir, 'output');
if exist(out_dir, 'dir') ~= 7, mkdir(out_dir); end
save(fullfile(out_dir, ['ex18_bscan_' opts.Timestamp '.mat']), 'results');
fprintf('B-scan 已保存至 %s\n', out_dir);
end

function opts = parse_bscan_opts(varargin)
% 解析 B-scan 参数
p = inputParser;
p.addParameter('NScans', 121, @(x) isscalar(x) && x >= 2);       % 扫描位置数
p.addParameter('NFFT', 4096, @(x) isscalar(x) && x >= 2);        % IFFT 长度
p.addParameter('BackgroundMode', 'model', @(x) ischar(x));       % 背景扣除模式：'model' 或 'none'
p.addParameter('MaxTime_ns', 80, @(x) isscalar(x) && x > 0);     % 显示最大时延 (ns)
p.addParameter('SaveFig', true);                                  % 是否保存图像
p.parse(varargin{:});
opts = p.Results;
end

function ensure_workspace()
% 确保工作区有 cfg 变量，没有则运行 setup_ex18_sfw 生成
if ~evalin('base', 'exist(''cfg'', ''var'')')
    setup_ex18_sfw();
end
end

function state = build_bscan_state(gpr, freq_hz)
% 预计算土壤电磁参数和杂波（所有扫描位置共用，避免重复计算）。
eps0 = 8.854187817e-12;    % 真空介电常数 (F/m)
mu0 = 4*pi*1e-7;           % 真空磁导率 (H/m)
c0 = 1/sqrt(mu0*eps0);     % 真空光速 (m/s)
eta0 = sqrt(mu0/eps0);     % 真空波阻抗 (Ω)

omega = 2*pi*freq_hz(:);   % 角频率 (rad/s)
eps_soil = eps0 * gpr.soil_eps_r;  % 土壤复介电常数实部

% 土壤传播常数 γ = √(jωμ·(σ + jωε))
gamma_soil = sqrt(1i*omega*mu0 .* (gpr.soil_sigma_s_per_m + 1i*omega*eps_soil));
% 土壤波阻抗 η = √(jωμ / (σ + jωε))
eta_soil = sqrt((1i*omega*mu0) ./ (gpr.soil_sigma_s_per_m + 1i*omega*eps_soil));

state = struct();
state.gpr = gpr;
state.freq_hz = freq_hz(:);
state.gamma_soil = gamma_soil;
state.k_air = omega / c0;           % 空气中的波数
state.surface_gamma = (eta_soil - eta0) ./ (eta_soil + eta0);  % 空气-土壤界面的 Fresnel 反射系数
state.transmission_product = (2*eta_soil./(eta_soil+eta0)) .* (2*eta0./(eta_soil+eta0));  % 双程透射系数乘积
state.clutter = build_clutter_bscan(gpr);  % 生成随机杂波散射体
state.c0 = c0;
end

function [channel, parts] = channel_response_bscan(scan_x_m, state)
% 计算单个扫描位置的完整通道频响，包含直耦、地表、杂波、目标四部分。
gpr = state.gpr;
freq_hz = state.freq_hz;

x_tx = scan_x_m - gpr.txrx_spacing_m/2;  % 发射天线 x 坐标
x_rx = scan_x_m + gpr.txrx_spacing_m/2;  % 接收天线 x 坐标

% --- 直耦（Tx → Rx 天线间直接耦合）---
cpl_dist = hypot(gpr.txrx_spacing_m, 0.01);
coupling = gpr.direct_coupling_amplitude .* ...
    exp(-1i*2*pi*freq_hz*(gpr.direct_extra_delay_s + cpl_dist/state.c0));

% --- 地表反射（Tx → 地表 → Rx）---
surf_path = hypot(gpr.txrx_spacing_m, 2*gpr.antenna_height_m);
surface = gpr.surface_reflectivity .* state.surface_gamma .* ...
    exp(-1i*state.k_air*surf_path);

% --- 杂波散射体（随机分布的点散射体集合）---
cl = zeros(size(freq_hz));
for idx = 1:numel(state.clutter.x_m)
    dtx = hypot(x_tx - state.clutter.x_m(idx), state.clutter.z_m(idx));
    drx = hypot(x_rx - state.clutter.x_m(idx), state.clutter.z_m(idx));
    path_m = dtx + drx;                        % 双程路径
    spread = 1/(1 + 1.15*path_m/2)^2;          % 几何扩散
    prop = exp(-state.gamma_soil*path_m);       % 土壤损耗
    cl = cl + state.clutter.reflectivity(idx) .* ...
        state.transmission_product .* spread .* prop;
end

% --- 管道目标反射（对所有目标体求和）---
target = zeros(size(freq_hz));
f_span = max(freq_hz(end) - freq_hz(1), eps);
for k = 1:numel(gpr.targets)
    tgt = gpr.targets(k);
    dx_tx = x_tx - tgt.center_x_m;
    dx_rx = x_rx - tgt.center_x_m;
    dtx_c = hypot(dx_tx, tgt.depth_m);
    drx_c = hypot(dx_rx, tgt.depth_m);
    dtx_s = max(dtx_c - tgt.radius_m, 0);
    drx_s = max(drx_c - tgt.radius_m, 0);
    path_m = dtx_s + drx_s;

    inc_tx = tgt.depth_m ./ max(dtx_c, 1e-6);
    inc_rx = tgt.depth_m ./ max(drx_c, 1e-6);
    ang_gain = (inc_tx .* inc_rx).^tgt.angular_taper;

    spread = 1./(1 + tgt.spreading_factor*path_m/2).^2;
    prop = exp(-state.gamma_soil*path_m);
    ripple = 1 + 0.05*cos(2*pi*(freq_hz - freq_hz(1))/f_span);

    target = target + tgt.reflectivity .* state.transmission_product .* ...
        ang_gain .* spread .* prop .* ripple;
end

% --- 合成总通道响应（含前端等效响应）---
direct = state.frontend .* coupling;
surf_resp = state.frontend .* surface;
cl_resp = state.frontend .* cl;
tgt_resp = state.frontend .* target;

channel = direct + surf_resp + cl_resp + tgt_resp;
parts = struct();
parts.direct = direct;
parts.surface = surf_resp;
parts.clutter = cl_resp;
parts.target = tgt_resp;
end

function response = frontend_response_bscan(freq_hz, gpr)
% 前端等效频响：模拟收发链路（放大器/滤波器/馈线）的幅相整形。
f_center = mean(freq_hz);
f_span = max(freq_hz(end) - freq_hz(1), eps);
f_norm = (freq_hz - f_center) / f_span;        % 归一化频率 [-0.5, 0.5]
amp = gpr.frontend_gain .* (1 + 0.07*cos(2*pi*1.35*f_norm) + ...
    0.03*sin(2*pi*2.6*f_norm));                % 幅度起伏
phase = -2*pi*freq_hz .* (3.8e-9 + 0.35e-9*sin(2*pi*0.95*f_norm));  % 相位/群时延起伏
response = amp .* exp(1i*phase);
end

function clutter = build_clutter_bscan(gpr)
% 根据配置参数生成随机杂波散射体：位置和复反射系数。
s = RandStream('mt19937ar', 'Seed', gpr.clutter_random_seed);  % 固定随机种子，确保可重复
n = gpr.clutter_count;
scan_lim = gpr.ref_scan_x_limits_m;
x_lim = scan_lim + [-0.2, 0.2];                % x 方向扩展范围
z_lim = gpr.clutter_depth_range_m;             % 深度范围
amp_lim = gpr.clutter_reflectivity_range;      % 反射率幅度范围

clutter = struct();
clutter.x_m = x_lim(1) + diff(x_lim)*rand(s, n, 1);         % 随机 x 坐标
clutter.z_m = z_lim(1) + diff(z_lim)*rand(s, n, 1);         % 随机 z 坐标
clutter.reflectivity = amp_lim(1) + diff(amp_lim)*rand(s, n, 1);  % 随机幅度
clutter.reflectivity = clutter.reflectivity .* exp(1i*2*pi*rand(s, n, 1));  % 随机相位
end

function plot_bscan(results, opts)
% 绘制 B-scan 灰度图。
time_mask = results.time_axis_ns <= opts.MaxTime_ns;
plot_time = results.time_axis_ns(time_mask);
bscan = real(results.time_profile(time_mask, :));

mx = max(abs(bscan(:)));
if mx == 0, mx = 1; end
clim = 0.55 * [-mx, mx];                       % 对称颜色映射范围，截断两端 45% 以增强对比

figure('Name', 'ex18 B-scan', 'NumberTitle', 'off');
imagesc(results.scan_x_m, plot_time, bscan, clim);
set(gca, 'YDir', 'reverse');                   % 时间轴从上到下（深→浅）
colormap(gray);
colorbar;
xlabel('扫描位置 (m)');
ylabel('双程走时 (ns)');
title(sprintf('ex18 B-scan (%d 个位置, %d 点 IFFT)', ...
    numel(results.scan_x_m), size(results.time_profile, 1)));

if opts.SaveFig
    out_dir = fullfile(fileparts(mfilename('fullpath')), 'output');
    if exist(out_dir, 'dir') ~= 7, mkdir(out_dir); end
    saveas(gcf, fullfile(out_dir, ['ex18_bscan_' opts.Timestamp '.png']));
end
end

function [fir_coeff, model] = ex18_make_ex08_soil_fir(gpr, sample_s)
%EX18_MAKE_SOIL_FIR 将频域土壤模型转换成 ex18 时域 FIR 通道。
%   Channel 按整段 SFCW 频谱计算土壤、地表、杂波和管道响应。
%   通过对各分量频响做 Hermitian IFFT 得到实系数 FIR 滤波器。

fs_hz = 1 / sample_s;
nfft = gpr.fir_nfft;
fir_len = gpr.fir_len;

if mod(nfft, 2) ~= 0
    error('ex18_make_ex08_soil_fir:BadNfft', 'gpr.fir_nfft 必须是偶数。');
end

freq_pos_hz = (0:nfft / 2).' * fs_hz / nfft;
freq_eval_hz = freq_pos_hz;
freq_eval_hz(1) = freq_pos_hz(2);

state = make_state(gpr, freq_eval_hz);
[channel_pos, parts] = channel_response(gpr.scan_x_m, state);
channel_pos(1) = channel_pos(2);

channel_full = [channel_pos; conj(channel_pos(end - 1:-1:2))];
impulse = real(ifft(channel_full));
fir_coeff = impulse(1:fir_len).';

model = struct();
model.frequency_hz = freq_pos_hz;
model.response = channel_pos;
model.impulse = impulse;
if isfield(gpr, 'sfcw_frequency_hz') && ~isempty(gpr.sfcw_frequency_hz)
    sfcw_state = make_state(gpr, gpr.sfcw_frequency_hz(:));
    [model.sfcw_response, model.sfcw_parts] = channel_response(gpr.scan_x_m, sfcw_state);
    model.sfcw_frequency_hz = gpr.sfcw_frequency_hz(:);
end
model.direct_gain = parts.direct_gain;
model.surface_gain = parts.surface_gain;
model.target_gain = parts.target_gain;
model.clutter_gain = parts.clutter_gain;
model.description = '均匀有损土壤/管道/杂波模型转换得到的时域 FIR';
end

function state = make_state(gpr, frequency_hz)
state = struct();
state.gpr = gpr;
state.frequency_hz = frequency_hz(:);
state.electrics = soil_electrics(gpr, state.frequency_hz);
state.frontend_response = frontend_response(state.frequency_hz, gpr);
state.clutter = build_clutter(gpr);
end

function [channel, parts] = channel_response(scan_x_m, state)
gpr = state.gpr;
electrics = state.electrics;

x_tx_m = scan_x_m - gpr.txrx_spacing_m / 2;
x_rx_m = scan_x_m + gpr.txrx_spacing_m / 2;

coupling_distance_m = hypot(gpr.txrx_spacing_m, 0.01);
coupling = gpr.direct_coupling_amplitude .* exp(-1i * 2 * pi * state.frequency_hz * ...
    (gpr.direct_extra_delay_s + coupling_distance_m / 299792458));

surface_path_m = hypot(gpr.txrx_spacing_m, 2 * gpr.antenna_height_m);
surface = gpr.surface_reflectivity .* electrics.surface_gamma .* ...
    exp(-1i * electrics.k_air * surface_path_m);

    clutter = clutter_response(x_tx_m, x_rx_m, state);
    % 对所有管道目标求和
    target = 0;
    for k = 1:numel(gpr.targets)
        target = target + pipe_response_single(gpr.targets(k), x_tx_m, x_rx_m, state);
    end

direct_response = state.frontend_response .* coupling;
surface_response = state.frontend_response .* surface;
clutter_response_value = state.frontend_response .* clutter;
target_response = state.frontend_response .* target;
channel = direct_response + surface_response + clutter_response_value + target_response;

parts = struct();
parts.direct_response = direct_response;
parts.surface_response = surface_response;
parts.clutter_response = clutter_response_value;
parts.target_response = target_response;
parts.background_response = direct_response + surface_response + clutter_response_value;
parts.direct_gain = abs(direct_response(nearest_center_index(state.frequency_hz)));
parts.surface_gain = abs(surface_response(nearest_center_index(state.frequency_hz)));
parts.target_gain = abs(target_response(nearest_center_index(state.frequency_hz)));
parts.clutter_gain = abs(clutter_response_value(nearest_center_index(state.frequency_hz)));
end

function idx = nearest_center_index(frequency_hz)
[~, idx] = min(abs(frequency_hz - mean(frequency_hz)));
end

function response = clutter_response(x_tx_m, x_rx_m, state)
gpr = state.gpr;
electrics = state.electrics;
scatterers = state.clutter;
response = zeros(numel(state.frequency_hz), 1);

for idx = 1:numel(scatterers.x_m)
    dtx_m = hypot(x_tx_m - scatterers.x_m(idx), scatterers.z_m(idx));
    drx_m = hypot(x_rx_m - scatterers.x_m(idx), scatterers.z_m(idx));
    path_m = dtx_m + drx_m;

    spreading = 1.0 / (1.0 + 1.15 * path_m / 2) ^ 2;
    propagation = exp(-electrics.gamma_soil * path_m);
    response = response + scatterers.reflectivity(idx) .* ...
        electrics.transmission_product .* spreading .* propagation;
end
end

function response = pipe_response_single(target, x_tx_m, x_rx_m, state)
%PIPE_RESPONSE_SINGLE 计算单个管道目标的频域响应。
%   target 是 cfg.gpr.targets(k) 结构体，包含：center_x_m, depth_m, radius_m,
%   reflectivity, spreading_factor, angular_taper。
electrics = state.electrics;

dx_tx_m = x_tx_m - target.center_x_m;
dx_rx_m = x_rx_m - target.center_x_m;
dtx_center_m = hypot(dx_tx_m, target.depth_m);
drx_center_m = hypot(dx_rx_m, target.depth_m);

dtx_surface_m = max(dtx_center_m - target.radius_m, 0);
drx_surface_m = max(drx_center_m - target.radius_m, 0);
path_m = dtx_surface_m + drx_surface_m;

incidence_tx = target.depth_m ./ max(dtx_center_m, 1e-6);
incidence_rx = target.depth_m ./ max(drx_center_m, 1e-6);
angular_gain = (incidence_tx .* incidence_rx) .^ target.angular_taper;

spreading = 1.0 ./ (1.0 + target.spreading_factor * path_m / 2) .^ 2;
propagation = exp(-electrics.gamma_soil * path_m);
freq_start_hz = state.frequency_hz(1);
freq_span_hz = max(state.frequency_hz(end) - state.frequency_hz(1), eps);
phase_ripple = 1.0 + 0.05 * cos(2 * pi * ...
    (state.frequency_hz - freq_start_hz) / freq_span_hz);

response = target.reflectivity .* electrics.transmission_product .* ...
    angular_gain .* spreading .* propagation .* phase_ripple;
end

function electrics = soil_electrics(gpr, frequency_hz)
eps0 = 8.854187817e-12;
mu0 = 4.0 * pi * 1.0e-7;
c0 = 1.0 / sqrt(mu0 * eps0);
eta0 = sqrt(mu0 / eps0);

omega = 2.0 * pi * frequency_hz(:);
eps_soil = eps0 * gpr.soil_eps_r;

gamma_soil = sqrt(1i * omega * mu0 .* ...
    (gpr.soil_sigma_s_per_m + 1i * omega * eps_soil));
eta_soil = sqrt((1i * omega * mu0) ./ ...
    (gpr.soil_sigma_s_per_m + 1i * omega * eps_soil));

electrics = struct();
electrics.gamma_soil = gamma_soil;
electrics.k_air = omega / c0;
electrics.surface_gamma = (eta_soil - eta0) ./ (eta_soil + eta0);
electrics.transmission_product = (2.0 * eta_soil ./ (eta_soil + eta0)) .* ...
    (2.0 * eta0 ./ (eta_soil + eta0));
end

function response = frontend_response(frequency_hz, gpr)
freq_center_hz = get_gpr_value(gpr, 'ref_center_frequency_hz', mean(frequency_hz));
freq_span_hz = get_gpr_value(gpr, 'ref_bandwidth_hz', ...
    max(frequency_hz(end) - frequency_hz(1), eps));
freq_norm = (frequency_hz - freq_center_hz) / freq_span_hz;

amplitude = gpr.frontend_gain .* (1.0 + 0.07 * cos(2 * pi * 1.35 * freq_norm) + ...
    0.03 * sin(2 * pi * 2.6 * freq_norm));
phase = -2 * pi * frequency_hz .* ...
    (3.8e-9 + 0.35e-9 * sin(2 * pi * 0.95 * freq_norm));
response = amplitude .* exp(1i * phase);
end

function clutter = build_clutter(gpr)
stream = RandStream('mt19937ar', 'Seed', gpr.clutter_random_seed);
n_clutter = gpr.clutter_count;
scan_x_limits_m = get_gpr_value(gpr, 'ref_scan_x_limits_m', [-1.05, 1.05]);
x_limits = scan_x_limits_m + [-0.2, 0.2];
z_limits = gpr.clutter_depth_range_m;
amp_limits = gpr.clutter_reflectivity_range;

clutter = struct();
clutter.x_m = x_limits(1) + diff(x_limits) * rand(stream, n_clutter, 1);
clutter.z_m = z_limits(1) + diff(z_limits) * rand(stream, n_clutter, 1);
clutter.reflectivity = amp_limits(1) + diff(amp_limits) * rand(stream, n_clutter, 1);
clutter.reflectivity = clutter.reflectivity .* exp(1i * 2 * pi * rand(stream, n_clutter, 1));
end

function value = get_gpr_value(gpr, field_name, default_value)
if isfield(gpr, field_name) && ~isempty(gpr.(field_name))
    value = gpr.(field_name);
else
    value = default_value;
end
end

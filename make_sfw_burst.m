function [src_ts, freq_ts, meta] = make_sfw_burst(freq_hz, coef, varargin)
%MAKE_SFW_BURST 生成步进频率波形脉冲串。
%
%   freq_hz(k) 是第 k 个步进频率。coef(k) 用
%   amp(k) * exp(1j * phase(k)) 的形式保存该频点的幅度和相位。
%   输出 src_ts 是 Simulink 可读取的时间序列，每个 PRI 内包含一个单频信号。

opts = parse_opts(freq_hz, varargin{:});
[freq_sel, coef_sel, step_idx] = pick_steps(freq_hz, coef, opts);
grid = make_time_grid(numel(freq_sel), opts);
src = make_burst_signal(freq_sel, coef_sel, grid, opts);

src_ts = timeseries(src, grid.t_s);
freq_ts = timeseries(freq_sel * 1e-6, grid.step_start_s);
meta = make_meta(freq_sel, step_idx, grid, opts);
end

function opts = parse_opts(freq_hz, varargin)
parser = inputParser;
parser.addParameter('StepCount', min(5, numel(freq_hz)));
parser.addParameter('StartIndex', 1);
parser.addParameter('PRI', 10e-6);
parser.addParameter('PulseWidth', 10e-6);
parser.addParameter('SampleRate', 500e6);
parser.addParameter('UseAbsTime', true);
parser.addParameter('PhaseContinuous', false);
parser.parse(varargin{:});

opts.step_count = max(1, round(parser.Results.StepCount));
opts.start_idx = max(1, round(parser.Results.StartIndex));
opts.pri_s = parser.Results.PRI;
opts.pulse_s = parser.Results.PulseWidth;
opts.fs_hz = parser.Results.SampleRate;
opts.use_abs_time = logical(parser.Results.UseAbsTime);
opts.phase_continuous = logical(parser.Results.PhaseContinuous);

validate_opts(opts);
end

function validate_opts(opts)
if opts.pri_s <= 0
    error('make_sfw_burst:BadPRI', 'PRI must be positive.');
end

if opts.pulse_s <= 0
    error('make_sfw_burst:BadPulseWidth', 'PulseWidth must be positive.');
end

if opts.pulse_s > opts.pri_s
    error('make_sfw_burst:PulseExceedsPRI', ...
        'PulseWidth must be less than or equal to PRI.');
end

if opts.fs_hz <= 0
    error('make_sfw_burst:BadSampleRate', 'SampleRate must be positive.');
end
end

function [freq_sel, coef_sel, step_idx] = pick_steps(freq_hz, coef, opts)
freq_hz = freq_hz(:);
coef = coef(:);

if numel(coef) ~= numel(freq_hz)
    error('make_sfw_burst:SizeMismatch', ...
        'freq_hz and coef must have the same length.');
end

stop_idx = min(numel(freq_hz), opts.start_idx + opts.step_count - 1);
step_idx = (opts.start_idx:stop_idx).';
freq_sel = freq_hz(step_idx);
coef_sel = coef(step_idx);
end

function grid = make_time_grid(step_count, opts)
samples_per_pri = max(1, round(opts.pri_s * opts.fs_hz));
fs_hz = samples_per_pri / opts.pri_s;
sample_s = 1 / fs_hz;
samples_per_pulse = max(1, round(opts.pulse_s * fs_hz));
pulse_s = samples_per_pulse * sample_s;

total_samples = step_count * samples_per_pri + 1;
grid = struct();
grid.fs_hz = fs_hz;
grid.sample_s = sample_s;
grid.samples_per_pri = samples_per_pri;
grid.samples_per_pulse = samples_per_pulse;
grid.pulse_s = pulse_s;
grid.stop_s = step_count * opts.pri_s;
grid.t_s = (0:total_samples - 1).' * sample_s;
grid.step_start_s = (0:step_count - 1).' * opts.pri_s;
end

function src = make_burst_signal(freq_hz, coef, grid, opts)
src = zeros(numel(grid.t_s), 1);
phase_acc_rad = angle(coef(1));

for k = 1:numel(freq_hz)
    first = (k - 1) * grid.samples_per_pri + 1;
    last = min(first + grid.samples_per_pulse - 1, numel(grid.t_s));
    sample_idx = first:last;

    local_t_s = grid.t_s(sample_idx) - (k - 1) * opts.pri_s;
    if opts.use_abs_time
        tone_t_s = grid.t_s(sample_idx);
    else
        tone_t_s = local_t_s;
    end

    amp = abs(coef(k));
    if opts.phase_continuous
        src(sample_idx) = amp .* cos(2 * pi * freq_hz(k) .* local_t_s + phase_acc_rad);
        phase_acc_rad = mod(phase_acc_rad + 2 * pi * freq_hz(k) * opts.pri_s, 2 * pi);
    else
        phase_rad = angle(coef(k));
        src(sample_idx) = amp .* cos(2 * pi * freq_hz(k) .* tone_t_s + phase_rad);
    end
end
end

function meta = make_meta(freq_hz, step_idx, grid, opts)
df_hz = 0;
if numel(freq_hz) > 1
    df_hz = mean(diff(freq_hz));
end

c0 = 299792458;
meta = struct();
meta.model = 'SFW burst';
meta.step_idx = step_idx;
meta.step_count = numel(freq_hz);
meta.pri_s = opts.pri_s;
meta.pulse_s = grid.pulse_s;
meta.duty = grid.pulse_s / opts.pri_s;
meta.fs_hz = grid.fs_hz;
meta.sample_s = grid.sample_s;
meta.samples_per_pri = grid.samples_per_pri;
meta.samples_per_pulse = grid.samples_per_pulse;
meta.stop_s = grid.stop_s;
meta.freq_hz = freq_hz;
meta.freq_mhz = freq_hz * 1e-6;
meta.df_hz = df_hz;
meta.pulse_start_s = grid.step_start_s;
meta.pulse_stop_s = grid.step_start_s + grid.pulse_s;
meta.use_abs_time = opts.use_abs_time;
meta.phase_continuous = opts.phase_continuous;

if df_hz > 0
    meta.range_res_m = c0 / (2 * numel(freq_hz) * df_hz);
    meta.unamb_range_m = c0 / (2 * df_hz);
else
    meta.range_res_m = Inf;
    meta.unamb_range_m = Inf;
end
end

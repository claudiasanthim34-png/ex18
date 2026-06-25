function ex18_observation_spectrum(varargin)
%ex18_observation_spectrum  生成 SFCW GPR (步进频率连续波探地雷达) 的 11 个频谱观测图谱
%   该函数会自动加载 Simulink 模型，插入探测节点(Probes)，运行仿真，提取各节点数据并绘图。

% 1. 环境与路径配置
work_dir = fileparts(mfilename('fullpath')); % 获取当前脚本所在目录
addpath(work_dir);                           % 将工作目录加入系统路径
addpath(fullfile(work_dir, 'patches'));      % 加入补丁/附属代码目录

% 2. 输入参数解析 (支持设置是否显示图片'Visible'和输出目录'OutputDir')
p = inputParser;
p.addParameter('Visible', 'on', @(x) ischar(x) || isstring(x));
p.addParameter('OutputDir', fullfile(work_dir, 'results'), @(x) ischar(x) || isstring(x));
p.parse(varargin{:});
opts = p.Results;
opts.Visible = char(opts.Visible);
opts.OutputDir = char(opts.OutputDir);
if exist(opts.OutputDir, 'dir') ~= 7, mkdir(opts.OutputDir); end % 如果输出目录不存在则创建

% 3. 模型配置与加载
model = 'ex18_sfw_top';
model_file = fullfile(work_dir, [model '.slx']);

fprintf('=== Step 1: Apply probe patches (第一步：应用探针补丁) ===\n');
if bdIsLoaded(model), close_system(model, 1); end % 如果模型已打开，先不保存直接关闭
load_system(model_file); % 加载模型

% 检查模型中是否已经存在探测点(probe)，如果没有则通过代码动态添加
if isempty(find_system(model, 'SearchDepth', 1, 'Name', 'probe_sfw_src'))
    fprintf('  Adding probes... (正在添加探针...)\n');
    close_system(model, 0); % 关闭并保存
    patch_add_probes();     % 调用外部函数添加探针
    load_system(model_file);% 重新加载修改后的模型
else
    fprintf('  Probes already exist. (探针已存在)\n');
end

% 设置模型的初始化回调函数并保存
set_param(model, 'InitFcn', 'setup_ex18_sfw;');
save_system(model);

fprintf('=== Step 2: Run simulation (第二步：运行 Simulink 仿真) ===\n');
evalin('base', sprintf('sim(''%s'')', model)); % 在基础工作区执行仿真指令
fprintf('  Simulation complete. (仿真完成)\n');

% 确保基础工作区(base workspace)中有配置变量 cfg
if ~evalin('base', 'exist(''cfg'', ''var'')'), setup_ex18_sfw(); end
cfg = evalin('base', 'cfg');
freq_hz = cfg.freq.hz(:);    % 步进频率数组
sim_fs = cfg.time.fs_hz;     % 仿真采样率
pri_s = cfg.time.pri_s;      % 脉冲重复周期 (PRI)
n_freq = numel(freq_hz);     % 频点数量

% --- Collect probe data (收集各探测点的数据) ---
% 定义需要提取的变量名及其对应的中文描述
probe_map = {
    'probe_sfw_src',            'SFW源';
    'probe_after_pa',           '发射天线前(PA后)';
    'probe_tx_radiated',        '发射天线后';
    'probe_rx_antenna_raw',     '接收回波';
    'probe_tap_mixer_raw',      '上变频混频';
    'probe_tap_up_bpf',         '上变频滤波';
    'probe_rx_down_mixer_raw',  '下变频混频';
    'probe_rx_down_if',         '200MHz中频';
    'probe_iq_mixer_raw',       'IQ混频';
    'probe_iq_baseband',        'IQ基带';
};
base_vars = evalin('base', 'who'); % 获取基础工作区的所有变量名
probes = {}; % 存储提取到的探针数据

for i = 1:size(probe_map, 1)
    vname = probe_map{i, 1};
    if any(strcmp(base_vars, vname)) % 如果工作区存在该探针变量
        try
            raw = evalin('base', vname); % 提取原始数据
            [t, v] = extract_uniform(raw); % 转换为均匀时间序列数据和时间向量
            if ~isempty(t) && ~isempty(v) && isnumeric(v)
                decim = 1; % 抽取(降采样)因子
                % 如果数据量过大(>10000)，进行等比例抽取以加快绘图和处理
                if numel(v) > 10000
                    step = max(1, floor(numel(v) / 10000));
                    t = t(1:step:end); v = v(1:step:end);
                    decim = step;
                end
                % IQ混频和基带信号后续需要进行高级处理，保留其完整原始数据(未抽取)
                need_raw = any(contains(vname, {'iq_baseband', 'iq_mixer'}));
                % 将处理后的信号信息打包存入 probes cell 数组
                probes{end+1} = struct('name', vname, 'desc', probe_map{i,2}, ...
                    'time', t, 'value', v, 'decim', decim, ...
                    'raw', iif(need_raw, raw, []));
            end
        catch ME
            fprintf('  FAILED %s: %s\n', vname, ME.message); % 捕获并提示数据提取失败的异常
        end
    end
end

fprintf('=== Step 3: Found %d probes (第三步：找到 %d 个探测点数据) ===\n', numel(probes), numel(probes));

fprintf('=== Step 4: Generate 11 plots (第四步：生成并保存 11 张图表) ===\n');
% 依次调用绘图函数
pl1(probes, n_freq, pri_s, sim_fs, opts);
% pl2(probes, sim_fs, opts);
% pl3(probes, sim_fs, opts);
% pl4(probes, sim_fs, opts);
% pl5(probes, sim_fs, opts);
% pl6(probes, sim_fs, opts);
% pl7(probes, sim_fs, opts);
% pl8(probes, sim_fs, opts);
% pl9(probes, sim_fs, opts);
% pl10(probes, freq_hz, opts);
% pl11(probes, freq_hz, cfg, opts);

close_system(model, 0); % 任务结束，关闭模型
fprintf('=== Done: %s (运行完毕，文件保存在上述目录) ===\n', opts.OutputDir);
end

% ---------------------------
% 内联三目运算符 (类似 C 语言的 cond ? a : b)
function v = iif(cond, a, b)
if cond, v = a; else v = b; end
end

% =========================== Helpers (辅助函数) ===========================

% 根据探针名称查找其在 cell 数组中的索引
function idx = pidx(probes, name)
idx = 0;
for j = 1:numel(probes)
    if strcmp(probes{j}.name, name), idx = j; return; end
end
end

% 判断是否存在指定名称的探针数据
function ok = hasp(probes, name), ok = pidx(probes, name) > 0; end

% 获取探针的常规数据: 时间 t, 信号值 v, 描述 d, 降采样率 dec
function [t, v, d, dec] = gp(probes, name)
idx = pidx(probes, name);
if idx > 0
    t = probes{idx}.time; v = probes{idx}.value;
    d = probes{idx}.desc; dec = probes{idx}.decim;
else
    t = []; v = []; d = ''; dec = 1;
end
end

% 获取探针的原始未经处理的数据 raw
function raw = gpr(probes, name)
idx = pidx(probes, name);
if idx > 0, raw = probes{idx}.raw; else raw = []; end
end

% 从不同格式的 Simulink 导出对象中提取时间 (t) 和数值向量 (v)
function [t, v] = extract_uniform(raw)
if isa(raw, 'timeseries') % timeseries 对象
    t = raw.Time; v = raw.Data;
elseif isstruct(raw) && isfield(raw, 'time') && isfield(raw, 'signals') % 结构体带time格式
    t = raw.time;
    if isstruct(raw.signals) && isfield(raw.signals, 'values')
        v = raw.signals.values;
    else v = raw.signals; end
elseif isa(raw, 'Simulink.SimulationData.Dataset') % Dataset 格式
    if raw.numElements < 1, t = []; v = []; return; end
    [t, v] = extract_uniform(raw{1}.Values); % 递归提取
elseif isa(raw, 'Simulink.SimulationData.Signal') % Signal 对象格式
    [t, v] = extract_uniform(raw.Values);
elseif isnumeric(raw) % 纯数值数组
    v = raw(:); t = (0:numel(v)-1).';
else t = []; v = []; end

% 数据清洗与对齐
if ~isempty(t)
    t = double(t(:)); v = squeeze(double(v));
    sz = size(v);
    % 处理多维矩阵的情况，只取最后的维度作为一维序列
    if ndims(v) >= 3 || (numel(sz) >= 2 && sz(2) > 1)
        v = v(:, :, end); v = v(:);
        if numel(v) > 1
            t = (0:numel(v)-1).' / max(diff(t(1:min(2,end))), eps); % 重构时间轴
        end
    else
        v = v(:); n = min(numel(t), numel(v));
        t = t(1:n); v = v(1:n); % 确保长度一致
    end
end
end

% 单边 FFT 频谱计算 (主要用于实信号)
% 返回: f(频率向量), m(幅度对数dB值向量)
function [f, m] = ssfft(v, fs, fmax)
n = numel(v);
if n < 4, f = []; m = []; return; end
nfft = 2^nextpow2(min(n, 2^16)); % 取最接近的2的幂次方作为FFT点数以加速
win = (0.5 - 0.5 * cos(2 * pi * (0:(n-1)).' ./ max(n-1, 1))); % 汉宁窗 (Hanning Window) 减小频谱泄漏
spec = fft(real(v(:)) .* win, nfft);
h = floor(nfft/2) + 1; % 提取正半轴频率部分
f = (0:(h-1)).' .* (fs ./ nfft);
m = abs(spec(1:h));
if max(m) > 0, m = 20 .* log10(m ./ max(m)); else m(:) = -100; end % 归一化并转为 dB
if nargin >= 3 && ~isempty(fmax) % 截断高频部分
    mask = f <= fmax; f = f(mask); m = m(mask);
end
end

% 双边 FFT 频谱计算 (主要用于 IQ 复信号)
function [f, m] = dsfft(v, fs, flim)
n = numel(v);
if n < 4 || isreal(v), f = []; m = []; return; end % 若为实数则不适用双边处理，直接返回
nfft = 2^nextpow2(min(n, 2^16));
win = (0.5 - 0.5 * cos(2 * pi * (0:(n-1)).' ./ max(n-1, 1)));
spec = fftshift(fft(v(:) .* win, nfft)); % fftshift 将零频移至中心
f = (-nfft/2:(nfft/2-1)).' .* (fs ./ nfft);
m = abs(spec);
if max(m) > 0, m = 20 .* log10(m ./ max(m)); else m(:) = -100; end
if nargin >= 3 && ~isempty(flim) % 截取指定的频带范围
    mask = abs(f) <= flim; f = f(mask); m = m(mask);
end
end

% 保存图像辅助函数
function sf(fig, name, opts)
fn = fullfile(opts.OutputDir, name);
try exportgraphics(fig, fn, 'Resolution', 150); % 推荐的高质量导出
catch, saveas(fig, fn); end % 兼容旧版 MATLAB
fprintf('  Saved: %s\n', fn);
if strcmpi(opts.Visible, 'off'), close(fig); end % 如果设置为不显示，保存后立刻关闭句柄
end

% =========================== Fig 1: SFW源时频图 ===========================
function pl1(probes, n_freq, pri_s, sim_fs, opts)
if ~hasp(probes, 'probe_sfw_src'), fprintf('  SKIP Fig1\n'); return; end
[t, v, ~, dec] = gp(probes, 'probe_sfw_src');
fs_eff = sim_fs / dec; % 补偿降采样后的等效采样率

fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 600]);

% 子图 1: SFW 源信号时域波形 (仅展示前 nshow 个脉冲的区间)
subplot(2,1,1);
% nshow = min(50, n_freq); 
nshow = n_freq;
n_samples = min(nshow * 10000, numel(v));
plot(t(1:n_samples) * 1e9, real(v(1:n_samples)), 'b-');
grid on; xlabel('Time (ns)'); ylabel('Amplitude');
title(sprintf('SFW source: time domain (first %d PRIs)', nshow));

% 子图 2: 短时傅里叶变换时频图 (Spectrogram)
subplot(2,1,2);
try
    win_len = min(256, max(64, round(numel(v)/200)));
    spectrogram(real(v), hann(win_len), round(win_len*0.75), ...
        2^nextpow2(min(win_len*4, 2048)), fs_eff, 'yaxis');
    colormap('jet'); colorbar('off'); ylim([0 500]);
    title('SFW source: spectrogram');
catch ME % 捕获可能的频谱绘制错误
    text(0.5, 0.5, ['spectrogram: ' ME.message], 'Units', 'normalized', 'HorizontalAlignment', 'center');
end
sf(fig, 'ex18_01_SFW源_时频图.png', opts);
end

% =========================== Fig 2: 发射天线前后频谱 ===========================
function pl2(probes, sim_fs, opts)
hb = hasp(probes, 'probe_after_pa'); ha = hasp(probes, 'probe_tx_radiated');
if ~hb && ~ha, fprintf('  SKIP Fig2\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 500]);

% 发射天线前(功率放大器PA后)的频谱
if hb
    subplot(2,1,1);
    [~, v, ~, dec] = gp(probes, 'probe_after_pa');
    [f, m] = ssfft(v, sim_fs/dec, 500e6);
    if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('Before TX antenna (PA output)'); xlim([0 500]); end
end
% 经过发射天线后的空间辐射频谱
if ha
    subplot(2,1,2);
    [~, v, ~, dec] = gp(probes, 'probe_tx_radiated');
    [f, m] = ssfft(v, sim_fs/dec, 500e6);
    if ~isempty(f), plot(f/1e6, m, 'r-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('After TX antenna (TX_Radiator)'); xlim([0 500]); end
end
sf(fig, 'ex18_02_发射天线前后频谱.png', opts);
end

% =========================== Fig 3: 接收回波原始频谱 ===========================
function pl3(probes, sim_fs, opts)
% 兼容可能存在的不同探针名称
nms = {'probe_rx_antenna_raw', 'probe_after_gpr_channel'}; found = '';
for i = 1:numel(nms), if hasp(probes, nms{i}), found = nms{i}; break; end; end
if isempty(found), fprintf('  SKIP Fig3\n'); return; end

fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, desc, dec] = gp(probes, found);
[f, m] = ssfft(v, sim_fs/dec, 500e6); % 计算 0-500MHz 频谱
if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title(sprintf('RX echo: %s', desc)); xlim([0 500]); end
sf(fig, 'ex18_03_接收回波原始频谱.png', opts);
end

% =========================== Fig 4: 上变频混频后宽频频谱 ===========================
function pl4(probes, sim_fs, opts)
if ~hasp(probes, 'probe_tap_mixer_raw'), fprintf('  SKIP Fig4\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_tap_mixer_raw');
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('Upconversion mixer wideband (Tap_Mixer_200MHz)'); xlim([0 500]);
    % 标出 200MHz 本振(LO) 所在位置
    hold on; plot([200 200], ylim, 'r--'); text(205, max(m)*0.8, 'LO=200MHz', 'Color', 'r');
end
sf(fig, 'ex18_04_上变频混频后宽频频谱.png', opts);
end

% =========================== Fig 5: 上变频滤波后上边带频谱 ===========================
function pl5(probes, sim_fs, opts)
if ~hasp(probes, 'probe_tap_up_bpf'), fprintf('  SKIP Fig5\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_tap_up_bpf');
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('Upconversion BPF upper sideband (210-480 MHz)'); xlim([0 500]);
    % 绘制绿色半透明色块高亮显示所需上边带区域 (210~480 MHz)
    hold on; yl = ylim;
    fill([210 210 480 480], [yl(1) yl(2) yl(2) yl(1)], 'g', 'FaceAlpha', 0.08, 'EdgeColor', 'none');
    text(250, max(m)*0.85, 'Upper sideband', 'Color', 'g');
end
sf(fig, 'ex18_05_上变频滤波后上边带频谱.png', opts);
end

% =========================== Fig 6: 下变频混频后宽频频谱 ===========================
function pl6(probes, sim_fs, opts)
if ~hasp(probes, 'probe_rx_down_mixer_raw'), fprintf('  SKIP Fig6\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_rx_down_mixer_raw');
[f, m] = ssfft(v, sim_fs/dec, 500e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('Downconversion mixer wideband (RX_Down_Mixer)'); xlim([0 500]);
    % 标定200MHz参考线
    hold on; plot([200 200], ylim, 'r--'); text(205, max(m)*0.8, 'LO=200MHz', 'Color', 'r');
end
sf(fig, 'ex18_06_下变频混频后宽频频谱.png', opts);
end

% =========================== Fig 7: 200MHz中频局部频谱 ===========================
function pl7(probes, sim_fs, opts)
if ~hasp(probes, 'probe_rx_down_if'), fprintf('  SKIP Fig7\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1000 400]);
[~, v, ~, dec] = gp(probes, 'probe_rx_down_if');
[f, m] = ssfft(v, sim_fs/dec, 300e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('200MHz IF local spectrum (190-210 MHz)'); xlim([160 240]); % 局部放大显示
    % 高亮所需的中频(IF)带宽区间 (190~210MHz)
    hold on; yl = ylim;
    fill([190 190 210 210], [yl(1) yl(2) yl(2) yl(1)], 'g', 'FaceAlpha', 0.08, 'EdgeColor', 'none');
    plot([200 200], yl, 'r--'); text(201, max(m)*0.85, 'IF=200MHz', 'Color', 'r');
end
sf(fig, 'ex18_07_200MHz中频局部频谱.png', opts);
end

% =========================== Fig 8: IQ混频后双边复频谱 ===========================
function pl8(probes, sim_fs, opts)
if ~hasp(probes, 'probe_iq_mixer_raw'), fprintf('  SKIP Fig8\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 900 400]);
[~, v, ~, dec] = gp(probes, 'probe_iq_mixer_raw');
% 提取 +/-30MHz 范围的双边谱
[f, m] = dsfft(v, sim_fs/dec, 30e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('IQ mixer double-sided spectrum (+/-30 MHz)');
else
    % 如果不支持双边(比如因数据异常成了实信号)，降级回退到单边显示
    [f, m] = ssfft(v, sim_fs/dec, 30e6);
    if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('IQ mixer single-sided (real signal)'); end
end
sf(fig, 'ex18_08_IQ混频后双边复频谱.png', opts);
end

% =========================== Fig 9: IQ基带双边频谱 ===========================
function pl9(probes, sim_fs, opts)
if ~hasp(probes, 'probe_iq_baseband'), fprintf('  SKIP Fig9\n'); return; end
fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 900 400]);
[~, v, ~, dec] = gp(probes, 'probe_iq_baseband');
% 提取基带信号 (+/- 20MHz内)
[f, m] = dsfft(v, sim_fs/dec, 20e6);
if ~isempty(f)
    plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
    title('IQ baseband double-sided spectrum (+/-20 MHz)');
    hold on; plot([0 0], ylim, 'r--'); % 标记 0Hz 的直流/中心位置
else
    [f, m] = ssfft(v, sim_fs/dec, 20e6);
    if ~isempty(f), plot(f/1e6, m, 'b-'); grid on; xlabel('Freq (MHz)'); ylabel('dB');
        title('IQ baseband single-sided (real signal)'); end
end
sf(fig, 'ex18_09_IQ基带双边频谱.png', opts);
end

% =========================== Fig 10: IFFT前后复频响与脉冲压缩验证 ===========================
function pl10(probes, freq_hz, opts)
if ~hasp(probes, 'probe_iq_baseband'), fprintf('  SKIP Fig10\n'); return; end
raw = gpr(probes, 'probe_iq_baseband'); % 这里需要未经降采样的原始IQ数据来分段截取
cfg_pri = 1e-6; cfg_fs = 1e9;
try c = evalin('base', 'cfg'); cfg_pri = c.time.pri_s; cfg_fs = c.time.fs_hz; catch; end
n_freq = numel(freq_hz);

% 外部函数 ex18_step_spectrum_probe 用于按 PRI 分段提取每个频率步进的稳态复数值
spec = ex18_step_spectrum_probe(raw, freq_hz, n_freq, cfg_pri, cfg_fs);
resp = spec.complex_response; amp = spec.amp_db; ph = spec.phase_rad;
valid = spec.valid; bad = ~valid;

% 线性插值修补失效点 (如果提取过程中有未能正确锁定的频段数据)
if any(bad)
    gd = find(valid); bd = find(bad);
    if numel(gd) >= 2
        resp(bd) = interp1(gd, resp(gd), bd, 'linear', 'extrap');
        amp(bd) = interp1(gd, amp(gd), bd, 'linear', 'extrap');
        ph(bd) = interp1(gd, ph(gd), bd, 'linear', 'extrap');
    end
end

% 进行逆傅里叶变换 (IFFT)，将频域回波转换到"距离域 / 时延域" (生成A-Scan)
nfft = 4096; 
win = 0.5 - 0.5 * cos(2*pi*(0:n_freq-1).' ./ max(n_freq-1,1)); % 频域加窗降低旁瓣
ascan = ifft(resp .* win, nfft);

% 再把合成出来的时域结果做一次正向 FFT 以验证幅度谱能否还原回去
ascan_fft_mag = abs(fft(ascan, nfft));
h = floor(nfft/2) + 1;
ascan_mag_db = 20 * log10(ascan_fft_mag(1:h) / max(ascan_fft_mag(1:h) + eps) + eps);
ascan_freq = (0:h-1).' * mean(diff(freq_hz)); % 还原频带刻度

fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 550]);
subplot(2,1,1);
% 绘制双Y轴图形：左侧为实测原步进频点幅度，右侧为经IFFT再FFT重构出的幅度 (闭环验证)
yyaxis left; plot(freq_hz/1e6, amp, 'b-'); ylabel('Original Step Mag (dB)');
yyaxis right; msk = ascan_freq <= max(freq_hz);
plot(ascan_freq(msk)/1e6, ascan_mag_db(msk), 'r--'); ylabel('IFFT->FFT Mag (dB)');
grid on; xlabel('Frequency (MHz)'); title('IFFT: magnitude response comparison');
legend('Original Step', 'IFFT->FFT round-trip', 'Location', 'best');

subplot(2,1,2);
% 显示信号各步进频点对应的展开相位响应
plot(freq_hz/1e6, ph*180/pi, 'r-'); grid on;
xlabel('Frequency (MHz)'); ylabel('Phase (deg)');
title('Pre-IFFT phase response (Step segmented)');
xlim([0 max(freq_hz)/1e6]);
sf(fig, 'ex18_10_IFFT前后复频响曲线.png', opts);
end

% =========================== Fig 11: A-scan时延/深度一维成像图 ===========================
function pl11(probes, freq_hz, cfg, opts)
if ~hasp(probes, 'probe_iq_baseband'), fprintf('  SKIP Fig11\n'); return; end
raw = gpr(probes, 'probe_iq_baseband');
cfg_pri = 1e-6; cfg_fs = 1e9;
try cfg_pri = cfg.time.pri_s; cfg_fs = cfg.time.fs_hz; catch; end
n_freq = numel(freq_hz);

% 和 Figure 10 一样获取步进频域重构点响应
spec = ex18_step_spectrum_probe(raw, freq_hz, n_freq, cfg_pri, cfg_fs);
resp = spec.complex_response; valid = spec.valid;
if nnz(valid) < 10, fprintf('  SKIP Fig11: too few valid points\n'); return; end

% 插值修补
bad = ~valid;
if any(bad)
    gd = find(valid); bd = find(bad);
    if numel(gd) >= 2, resp(bd) = interp1(gd, resp(gd), bd, 'linear', 'extrap'); end
end

df = mean(diff(freq_hz)); % 频率步进间隔 df决定了无模糊探测范围
nfft = 4096;
win = 0.5 - 0.5 * cos(2*pi*(0:n_freq-1).' ./ max(n_freq-1,1));
ascan = ifft(resp .* win, nfft); % 将频响IFFT为时域脉冲
amp_val = abs(ascan);

% 构造 IFFT 得到的时延轴 (双向传播时间)
t_axis = (0:nfft-1).' / (nfft * df);
v_soil = 1e8; % 雷达波在土壤中的传播速度预设为 1e8 m/s
try v_soil = cfg.gpr.soil_velocity_mps; catch; end
% 转换到深度域：距离 = 速度 * 时间 / 2 (雷达双向往返衰减)
d_axis = v_soil * t_axis / 2; 

fig = figure('Visible', opts.Visible, 'Color', 'w', 'Position', [100 100 1100 500]);
msk = t_axis <= 100e-9; % 限制绘图只显示前 100 纳秒的回波以便于观测浅层

% 子图 1: A-scan 回波时延域图像
subplot(1,2,1);
plot(t_axis(msk)*1e9, amp_val(msk), 'b-'); grid on;
xlabel('Delay (ns)'); ylabel('Amplitude'); title('A-scan: Delay domain');
% 尝试从模型配置中读取预设的目标位置并绘制绿色垂直虚线作为真实对比 (Ground Truth)
try
    hold on;
    for k = 1:numel(cfg.gpr.targets)
        d = cfg.gpr.targets(k).delay_s * 1e9;
        plot([d d], ylim, 'g--', 'LineWidth', 1.2);
    end
catch; end

% 子图 2: A-scan 回波深度域图像
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
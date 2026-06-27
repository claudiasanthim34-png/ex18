function result = ex18_module_transfer_spectrum(probe_in, probe_out, varargin)
%ex18_module_transfer_spectrum  计算模块的传递函数 H(f) = Y(f)/X(f)
%
%   输入参数:
%     probe_in  - 输入探针数据 (在模块输入端采集的数据)
%     probe_out - 输出探针数据 (在模块输出端采集的数据)
%
%   键值对选项 (Name-Value options):
%     'ModuleName', ''         - 模块名称 (将用于绘图的标题)
%     'FreqHz', []             - 频率轴数据 (如果为空，则会自动检测或生成)
%     'StepCount', []          - 频率步进的总数 (频点数量)
%     'PRIS', 1e-6             - 脉冲重复间隔 (PRI) 时长，单位：秒 (默认 1 微秒)
%     'FsHz', 1e9              - 采样率，单位：Hz (默认 1 GHz)
%     'SaveFig', false         - 布尔值，是否保存生成的图表 (默认：不保存)
%     'OutputDir', 'results'   - 图片保存的输出目录路径 (默认文件夹：'results')
%     'Visible', 'on'          - 图表的可见性设置 ('on' 或 'off')
%
%   输出结果:
%     result.freq_hz   - 频率轴 (Hz)
%     result.gain_db   - 增益 (dB)，计算公式为 20*log10(|H|)
%     result.phase_rad - 相位，单位：弧度 (radians)
%     result.complex_h - 复数形式的传递函数结果

% -- 1. 解析输入参数 --
p = inputParser; % 创建输入解析器对象
p.addParameter('ModuleName', '');
p.addParameter('FreqHz', []);
p.addParameter('StepCount', []);
p.addParameter('PRIS', 1e-6);
p.addParameter('FsHz', 1e9);
p.addParameter('SaveFig', false);
p.addParameter('OutputDir', 'results');
p.addParameter('Visible', 'on');
p.parse(varargin{:}); % 解析传入的变长参数
opts = p.Results;     % 获取解析后的参数结果字典

% -- 2. 确定频率轴 (Resolve frequency axis) --
freq_hz = opts.FreqHz;
step_count = opts.StepCount;
pri_s = opts.PRIS;
fs_hz = opts.FsHz;

% 逻辑：如何获取频率轴数据
% 如果 FreqHz 为空，且 MATLAB 基础工作区 (base workspace) 中存在 'sfw_freq_hz' 变量
if isempty(freq_hz) && evalin('base', 'exist(''sfw_freq_hz'', ''var'')')
    freq_hz = evalin('base', 'sfw_freq_hz'); % 从工作区读取该变量
    step_count = numel(freq_hz);             % 步数即为频率数组的长度
% 如果 FreqHz 为空且工作区没有对应变量，则生成默认的频率轴
elseif isempty(freq_hz)
    step_count = max(1, round(step_count));  % 确保步数至少为 1
    % 生成一个从 20MHz 开始，步进为 0.5MHz 的频率列向量
    freq_hz = (0:step_count - 1).' * 0.5e6 + 20e6;
end

% -- 3. 计算输入和输出信号的步进频谱 --
% 调用外部函数 ex18_step_spectrum_probe 获取输入和输出的频谱响应
spec_in = ex18_step_spectrum_probe(probe_in, freq_hz, step_count, pri_s, fs_hz);
spec_out = ex18_step_spectrum_probe(probe_out, freq_hz, step_count, pri_s, fs_hz);

% -- 4. 计算传递函数 (Compute transfer function) --
% 确定有效的数据点掩码 (Mask)：
% 必须满足输入有效、输出有效，且输入的复数响应幅值大于 1e-12（防止出现除以零或噪声放大的错误）
valid = spec_in.valid & spec_out.valid & ...
    (abs(spec_in.complex_response) > 1e-12);

% 初始化复数传递函数数组，全部填充为 NaN，大小与 freq_hz 相同
complex_h = complex(nan(size(freq_hz)));
% 仅在有效数据点上进行复数除法 H = Y / X
complex_h(valid) = spec_out.complex_response(valid) ./ spec_in.complex_response(valid);

% 计算增益 (dB)。使用 max(..., eps) 防止对 0 取对数导致 -Inf 错误
gain_db = 20 * log10(max(abs(complex_h), eps));
% 计算相位 (弧度)
phase_rad = angle(complex_h);

% -- 5. 封装输出结果 (Build output) --
result = struct();
result.freq_hz = freq_hz(:);      % 强制转换为列向量
result.gain_db = gain_db(:);      
result.phase_rad = phase_rad(:);  
result.complex_h = complex_h(:);  
result.valid = valid(:);          % 保存有效点掩码，用于后续绘图
result.module_name = opts.ModuleName;

% -- 6. 绘图调用 (Plot) --
% 如果用户没有请求任何输出参数（即直接在命令行运行）或者指定了 SaveFig 为 true，则执行绘图
if nargout == 0 || opts.SaveFig
    plot_transfer(result, opts);
end
end

% =========================================================================
% 辅助绘图子函数 (Subfunction for plotting)
% =========================================================================
function plot_transfer(result, opts)
module_name = opts.ModuleName;
if isempty(module_name)
    module_name = 'Module'; % 若未指定模块名，则赋予默认名称
end

f_mhz = result.freq_hz / 1e6; % 将频率单位从 Hz 转换为 MHz 以方便显示

% 创建图形窗口
fig = figure('Name', ['Transfer: ' module_name], ...
    'Visible', opts.Visible, 'Color', 'w', ...  % 设置背景色为白色，根据选项设置可见性
    'Position', [100 100 900 700]);             % 设置窗口起始位置和大小 [x, y, width, height]

% --- 绘制增益图 (Subplot 1) ---
subplot(2, 1, 1);
% 绘制完整的增益曲线（蓝线）
plot(f_mhz, result.gain_db, 'b-', 'LineWidth', 1.2);
grid on; % 打开网格
xlabel('Frequency (MHz)'); % X轴标签
ylabel('Gain (dB)');       % Y轴标签
title(sprintf('%s Transfer Function: Gain', module_name)); % 设置标题
hold on;
% 标出有效的数据点（蓝色圆点）
plot(f_mhz(result.valid), result.gain_db(result.valid), 'b.');
% 如果存在无效数据点，用红色 'x' 标出
if any(~result.valid)
    plot(f_mhz(~result.valid), result.gain_db(~result.valid), 'rx', ...
        'MarkerSize', 6);
end

% --- 绘制相位图 (Subplot 2) ---
subplot(2, 1, 2);
% 绘制完整的相位曲线（红线），将弧度转换为角度 ( * 180 / pi )
plot(f_mhz, result.phase_rad * 180 / pi, 'r-', 'LineWidth', 1.2);
grid on;
xlabel('Frequency (MHz)');
ylabel('Phase (deg)');
title(sprintf('%s Transfer Function: Phase', module_name));
hold on;
% 标出有效数据的相位点（红色圆点）
plot(f_mhz(result.valid), result.phase_rad(result.valid) * 180 / pi, 'r.');

% --- 保存图片逻辑 ---
if opts.SaveFig
    % 检查输出目录是否存在，如果不存在则创建 (7 代表目录)
    if exist(opts.OutputDir, 'dir') ~= 7
        mkdir(opts.OutputDir);
    end
    
    % 将模块名称中非字母数字下划线的字符替换为下划线，以生成合法的文件名
    safe_name = regexprep(module_name, '[^\w]', '_');
    fname = fullfile(opts.OutputDir, ...
        sprintf('transfer_%s.png', safe_name));
        
    % 尝试使用 exportgraphics (较新版本的 MATLAB 推荐) 保存高分辨率图片
    try
        exportgraphics(fig, fname, 'Resolution', 150);
    catch
        % 如果 exportgraphics 失败（旧版 MATLAB），则退回使用 saveas
        saveas(fig, fname);
    end
    fprintf('Saved: %s\n', fname); % 在控制台打印保存路径提示
end

% 如果用户设置图像不可见 ('off')，则在后台绘制并保存后自动关闭句柄，防止占用内存
if strcmpi(opts.Visible, 'off')
    close(fig);
end
end
function ex18_dsp_ascan_view(varargin)
%EX18_DSP_ASCAN_VIEW 运行 Simulink 仿真, 观察 DSP A-scan 管线输出的 A-scan。
%
%   流程:
%     1. 运行 setup_ex18_sfw 准备工作区变量
%     2. 运行 sim('ex18_sfw_top') 进行 SFCW 扫频仿真
%     3. 从 base workspace 读取 DSP 管线输出的 dsp_ascan_log
%     4. 绘制 DSP A-scan 并与 MATLAB 离线 IFFT A-scan 对比
%
%   用法:
%     ex18_dsp_ascan_view
%     ex18_dsp_ascan_view('StepCount', 100)  % 仅发射 100 个频点（快速预览）

    work_dir = fileparts(mfilename('fullpath'));
    addpath(work_dir);
    addpath(fullfile(work_dir, 'filterlib'));

    % --- 解析参数 ---
    p = inputParser;
    p.addParameter('StepCount', 501, @(x) isnumeric(x) && isscalar(x) && x >= 2);
    p.addParameter('SaveFig', false, @(x) islogical(x) || isnumeric(x));
    p.parse(varargin{:});
    opts = p.Results;

    % --- 1. 准备工作区 ---
    setup_ex18_sfw('StepCount', opts.StepCount);

    % --- 2. 运行 Simulink 仿真 ---
    fprintf('运行 SFCW 仿真 (%d 个频点)...\n', opts.StepCount);
    model = 'ex18_sfw_top';
    load_system(model);

    % 设置停止时间 = StepCount 个 PRI
    stop_time = opts.StepCount * evalin('base', 'sfw_pri_s') + 5e-6;
    set_param(model, 'StopTime', num2str(stop_time));

    sim_out = sim(model, 'ReturnWorkspaceOutputs', 'on');
    close_system(model, 0);
    fprintf('仿真完成。\n');

    % --- 3. 提取 DSP A-scan 日志 ---
    try
        dsp_log = sim_out.get('dsp_ascan_log');
        if isa(dsp_log, 'timeseries')
            dsp_time = dsp_log.Time;
            dsp_data = squeeze(dsp_log.Data);
        elseif isstruct(dsp_log) && isfield(dsp_log, 'time')
            dsp_time = dsp_log.time;
            dsp_data = dsp_log.signals.values;
        else
            error('Unsupported format');
        end
    catch ME
        fprintf('无法读取 dsp_ascan_log: %s\n', ME.message);
        return;
    end

    if isempty(dsp_data) || all(dsp_data(:) == 0)
        fprintf('DSP A-scan 数据为空。可能仿真时间不足，需要 %d 个 PRI。\n', opts.StepCount);
        return;
    end

    % --- 4. 读取 MATLAB 离线 A-scan 用于对比 ---
    results_mat = ex18_make_ascan('BackgroundMode', 'none', ...
        'NFFT', 4096, 'Visible', 'off', 'SaveResults', false);

    % --- 5. 绘图 ---
    fig = figure('Name', 'DSP A-scan vs MATLAB A-scan', ...
        'NumberTitle', 'off', 'Position', [100 100 1300 550], 'Color', 'w');

    % 子图1: DSP A-scan（Simulink 管线输出）
    subplot(1, 2, 1);
    nfft = 4096;
    delay_step_ns = 1 / (nfft * evalin('base', 'sfw_df_hz')) * 1e9;
    delay_axis_ns = (0:nfft-1)' * delay_step_ns;
    max_plot = min(nfft, numel(dsp_data));

    plot(delay_axis_ns(1:max_plot), dsp_data(1:max_plot), ...
        'Color', [0.1 0.35 0.7], 'LineWidth', 0.9);
    grid on;
    xlabel('Delay (ns)');
    ylabel('Amplitude');
    title(sprintf('DSP A-scan (Simulink) — %d freq points, N_{FFT}=%d', ...
        opts.StepCount, nfft));
    xlim([0 80]);

    % 标记目标理论位置
    hold on;
    if isfield(results_mat, 'Expected')
        t1 = results_mat.Expected.Targets(1);
        t2 = results_mat.Expected.Targets(2);
        yl = ylim;
        plot([t1.delay_s*1e9 t1.delay_s*1e9], yl, 'g--', 'LineWidth', 1.2);
        plot([t2.delay_s*1e9 t2.delay_s*1e9], yl, 'm--', 'LineWidth', 1.2);
        legend('DSP A-scan', ...
            sprintf('Target 1 (%.2f m)', t1.depth_m), ...
            sprintf('Target 2 (%.2f m)', t2.depth_m), ...
            'Location', 'northeast', 'FontSize', 8);
    end

    % 子图2: MATLAB IFFT A-scan
    subplot(1, 2, 2);
    plot_mask = results_mat.TimeAxisS <= 80e-9;
    plot(results_mat.TimeAxisS(plot_mask)*1e9, ...
        results_mat.Amplitude(plot_mask), ...
        'Color', [0.85 0.25 0.15], 'LineWidth', 0.9);
    grid on;
    xlabel('Delay (ns)');
    ylabel('Amplitude');
    title(sprintf('MATLAB IFFT A-scan — %d freq points', numel(results_mat.FrequencyHz)));
    xlim([0 80]);

    % 标记
    hold on;
    if isfield(results_mat, 'Expected')
        yl = ylim;
        plot([t1.delay_s*1e9 t1.delay_s*1e9], yl, 'g--', 'LineWidth', 1.2);
        plot([t2.delay_s*1e9 t2.delay_s*1e9], yl, 'm--', 'LineWidth', 1.2);
    end

    fprintf('DSP A-scan 峰值: %.4g, 样本数: %d\n', max(abs(dsp_data)), numel(dsp_data));
    fprintf('MATLAB A-scan 峰值: %.4g\n', max(results_mat.Amplitude));

    if opts.SaveFig
        out_dir = fullfile(work_dir, 'output');
        if exist(out_dir, 'dir') ~= 7, mkdir(out_dir); end
        fname = fullfile(out_dir, 'ex18_dsp_ascan_comparison.png');
        try
            exportgraphics(fig, fname, 'Resolution', 160);
        catch
            saveas(fig, fname);
        end
        fprintf('图像已保存: %s\n', fname);
    end
end

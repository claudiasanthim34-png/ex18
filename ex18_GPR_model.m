function ex18_plot_setup(varargin)
%EX18_PLOT_SETUP 绘制 ex18 SFCW GPR 土壤模型和天线扫描计划图。
%
%   生成两张图:
%     Fig 1 — 土壤剖面模型（横截面）：天线、目标管道、杂波、传播路径
%     Fig 2 — 天线扫描计划（俯视图）：扫描轨迹、目标投影、固定A扫位置
%
%   用法:
%     ex18_plot_setup                           % 从 base workspace 读取 cfg
%     ex18_plot_setup('RunSetup', true)         % 先运行 setup_ex18_sfw 再绘图
%     ex18_plot_setup('SaveFigs', true)         % 保存到 output/

    opts = parse_plot_opts(varargin{:});

    if opts.RunSetup
        setup_ex18_sfw();
    end

    if ~evalin('base', 'exist(''cfg'', ''var'')')
        fprintf('base workspace 中没有 cfg，正在自动运行 setup_ex18_sfw ...\n');
        setup_ex18_sfw();
    end

    cfg = evalin('base', 'cfg');
    gpr = cfg.gpr;

    plot_soil_cross_section(gpr, opts);
    plot_scan_plan(gpr, cfg, opts);

    fprintf('Setup plots generated.\n');
end

function opts = parse_plot_opts(varargin)
    p = inputParser;
    p.addParameter('RunSetup', false, @(x) islogical(x) || isnumeric(x));
    p.addParameter('SaveFigs', false, @(x) islogical(x) || isnumeric(x));
    p.addParameter('OutputDir', fullfile(fileparts(mfilename('fullpath')), 'output'), @ischar);
    p.parse(varargin{:});
    opts = p.Results;
end

%% ========================================================================
%  Fig 1: 土壤剖面模型（横截面）
% ========================================================================
function plot_soil_cross_section(gpr, opts)
    fig = figure('Name', 'ex18 土壤剖面模型', 'NumberTitle', 'off', ...
        'Position', [80 150 1100 650], 'Color', 'w');
    ax = axes('Parent', fig);
    axes(ax);  % 兼容旧版 MATLAB，避免 fill/scatter/grid 等不支持 ax 参数
    hold(ax, 'on');

    % --- 几何参数 ---
    ant_h   = gpr.antenna_height_m;
    spacing = gpr.txrx_spacing_m;
    scan_x  = gpr.scan_x_m;
    x_tx = scan_x - spacing/2;
    x_rx = scan_x + spacing/2;
    ep = gpr.soil_eps_r;
    sigma = gpr.soil_sigma_s_per_m;
    v_soil = 299792458 / sqrt(ep);

    % --- 确定坐标范围 ---
    x_lim = gpr.ref_scan_x_limits_m + [-0.5, 0.5];
    y_top = ant_h + 1.2;
    y_bot = -max([gpr.clutter_depth_range_m(2), ...
        max([gpr.targets.depth_m]) + max([gpr.targets.radius_m]) + 0.5]);

    xlim(x_lim);
    ylim([y_bot, y_top]);

    % === 空气区域 ===
    fill([x_lim(1) x_lim(2) x_lim(2) x_lim(1)], ...
        [0 0 y_top y_top], [0.85 0.92 1.0], 'EdgeColor', 'none', ...
        'FaceAlpha', 0.3, 'DisplayName', '空气 (c0 = 0.3 m/ns)');

    % === 土壤区域 ===
    fill([x_lim(1) x_lim(2) x_lim(2) x_lim(1)], ...
        [y_bot y_bot 0 0], [0.82 0.65 0.38], 'EdgeColor', 'none', ...
        'FaceAlpha', 0.45, 'DisplayName', ...
        sprintf('土壤 eps_r=%.0f sigma=%.3f S/m v=%.2f m/ns', ep, sigma, v_soil/1e9));

    % === 地表线 ===
    plot(x_lim, [0 0], 'Color', [0.25 0.50 0.15], 'LineWidth', 2.5, ...
        'DisplayName', '地表面');

    % === 天线 ===
    tx_color = [0.10 0.45 0.85];
    rx_color = [0.85 0.33 0.10];
    plot(x_tx, ant_h, 'v', 'MarkerSize', 16, 'MarkerFaceColor', tx_color, ...
        'MarkerEdgeColor', 'k', 'LineWidth', 1.2, 'DisplayName', 'Tx 天线');
    plot(x_rx, ant_h, 'v', 'MarkerSize', 16, 'MarkerFaceColor', rx_color, ...
        'MarkerEdgeColor', 'k', 'LineWidth', 1.2, 'DisplayName', 'Rx 天线');
    text(x_tx, ant_h + 0.35, 'Tx', 'FontSize', 11, 'FontWeight', 'bold', ...
        'Color', tx_color, 'HorizontalAlignment', 'center');
    text(x_rx, ant_h + 0.35, 'Rx', 'FontSize', 11, 'FontWeight', 'bold', ...
        'Color', rx_color, 'HorizontalAlignment', 'center');

    % 天线间距标注
    yy = ant_h - 0.25;
    plot([x_tx x_rx], [yy yy], 'k-', 'LineWidth', 1);
    text(scan_x, yy - 0.15, sprintf('间距 %.1f m', spacing), ...
        'FontSize', 9, 'HorizontalAlignment', 'center', 'Color', [0.3 0.3 0.3]);

    % === 直耦路径（虚线，空气） ===
    plot([x_tx x_rx], [ant_h ant_h], 'Color', [0.1 0.55 0.90], ...
        'LineStyle', '--', 'LineWidth', 1.2, 'DisplayName', '直耦 (空气)');

    % === 地表反射路径 ===
    refl_pt_x = scan_x;
    refl_pt_y = 0;
    plot([x_tx refl_pt_x x_rx], [ant_h refl_pt_y ant_h], ...
        'Color', [0.25 0.65 0.25], 'LineStyle', ':', 'LineWidth', 1.0, ...
        'DisplayName', '地表反射');

    % === 杂波散射体 ===
    rng(gpr.clutter_random_seed);
    n = gpr.clutter_count;
    c_x = x_lim(1) + 0.1 + (diff(x_lim) - 0.2) * rand(n, 1);
    c_z = gpr.clutter_depth_range_m(1) + ...
        diff(gpr.clutter_depth_range_m) * rand(n, 1);
    scatter(c_x, -c_z, 18, [0.6 0.55 0.5], 'o', 'filled', ...
        'MarkerFaceAlpha', 0.6, 'DisplayName', sprintf('杂波 (%d 点)', n));

    % === 目标管道 ===
    pcolors = pipe_colors();
    theta = linspace(0, 2*pi, 60);
    for k = 1:numel(gpr.targets)
        t = gpr.targets(k);
        cx = t.center_x_m;
        cz = -t.depth_m;
        r = t.radius_m;
        col = pcolors{min(k, numel(pcolors))};

        % 管道圆
        fill(cx + r*cos(theta), cz + r*sin(theta), col, ...
            'FaceAlpha', 0.55, 'EdgeColor', col*0.6, 'LineWidth', 1.8, ...
            'DisplayName', sprintf('管道 %d (r=%.0f mm z=%.2f m)', ...
            k, r*1000, t.depth_m));

        % 标注
        text(cx, cz - r - 0.18, sprintf('T%d', k), 'FontSize', 10, ...
            'FontWeight', 'bold', 'Color', col, 'HorizontalAlignment', 'center');

        % 目标反射路径
        dtx_c = hypot(x_tx - cx, ant_h - cz);
        drx_c = hypot(x_rx - cx, ant_h - cz);
        dtx_s = max(dtx_c - r, 0.001);
        drx_s = max(drx_c - r, 0.001);
        s_tx_x = cx + (x_tx - cx) * (dtx_s / dtx_c);
        s_tx_y = cz + (ant_h - cz) * (dtx_s / dtx_c);
        s_rx_x = cx + (x_rx - cx) * (drx_s / drx_c);
        s_rx_y = cz + (ant_h - cz) * (drx_s / drx_c);

        plot([x_tx s_tx_x s_rx_x x_rx], [ant_h s_tx_y s_rx_y ant_h], ...
            'Color', col, 'LineStyle', '-', 'LineWidth', 1.0, ...
            'DisplayName', sprintf('路径至管道 %d', k));
    end

    % === 图例和格式 ===
    xlabel('水平位置 (m)');
    ylabel('高度 / 深度 (m)');
    title(sprintf(...
        'ex18 土壤剖面模型 | A扫位置 x=%.1f m | 频率 %.0f-%.0f MHz', ...
        scan_x, gpr.ref_f_start_hz/1e6, gpr.ref_f_start_hz/1e6 + gpr.ref_bandwidth_hz), ...
        'FontSize', 12);
    grid on;
    box on;
    legend('Location', 'eastoutside', 'FontSize', 8);

    save_figure(fig, 'ex18_soil_profile', opts);
end

%% ========================================================================
%  Fig 2: 天线扫描计划（俯视图）
% ========================================================================
function plot_scan_plan(gpr, cfg, opts)
    fig = figure('Name', 'ex18 天线扫描计划', 'NumberTitle', 'off', ...
        'Position', [80 150 1100 450], 'Color', 'w');

    scan_lim = gpr.ref_scan_x_limits_m;
    scan_x = gpr.scan_x_m;
    x_lim = scan_lim + [-0.6, 0.6];
    pcolors = pipe_colors();

    % === 子图 1: 扫描线俯视图 ===
    subplot(2, 1, 1);
    hold on;

    xlim(x_lim);
    ylim([-1, 1]);

    % 扫描线
    plot(scan_lim, [0 0], 'k-', 'LineWidth', 3, 'DisplayName', 'B-scan 扫描线');
    text(scan_lim(1) - 0.1, -0.35, sprintf('%.1f m', scan_lim(1)), ...
        'FontSize', 8, 'HorizontalAlignment', 'center');
    text(scan_lim(2) + 0.1, -0.35, sprintf('%.1f m', scan_lim(2)), ...
        'FontSize', 8, 'HorizontalAlignment', 'center');

    % 扫描范围双箭头
    quiver(scan_lim(1), -0.45, diff(scan_lim), 0, 0, 'k', 'LineWidth', 1.2, ...
        'MaxHeadSize', 0.3);
    text(mean(scan_lim), -0.65, sprintf('扫描范围 = %.1f m (121 位置)', ...
        diff(scan_lim)), 'FontSize', 10, 'HorizontalAlignment', 'center', ...
        'Color', [0.2 0.2 0.2]);

    % 采样位置标记
    n_marks = 25;
    mark_x = linspace(scan_lim(1), scan_lim(2), n_marks);
    plot(mark_x, zeros(1, n_marks), 'k|', 'MarkerSize', 4, 'LineWidth', 0.5);

    % 固定 A-scan 位置
    plot(scan_x, 0, 'o', 'MarkerSize', 14, 'MarkerFaceColor', 'r', ...
        'MarkerEdgeColor', 'k', 'LineWidth', 1.5, ...
        'DisplayName', sprintf('A扫位置 x=%.2f', scan_x));
    text(scan_x, 0.28, 'A-scan', 'FontSize', 10, 'FontWeight', 'bold', ...
        'Color', 'r', 'HorizontalAlignment', 'center');

    % 目标投影
    for k = 1:numel(gpr.targets)
        tgt = gpr.targets(k);
        col = pcolors{min(k, numel(pcolors))};
        plot(tgt.center_x_m, 0, 's', 'MarkerSize', 12, ...
            'MarkerFaceColor', col, 'MarkerEdgeColor', 'k', ...
            'LineWidth', 1.2, ...
            'DisplayName', sprintf('管道 %d (深 %.2f m)', k, tgt.depth_m));
        text(tgt.center_x_m, 0.20, sprintf('T%d', k), 'FontSize', 9, ...
            'FontWeight', 'bold', 'Color', col, ...
            'HorizontalAlignment', 'center');
    end

    set(gca, 'YTick', []);
    xlabel('水平位置 (m)');
    title('天线扫描计划 | 俯视图', 'FontSize', 12);
    grid on;
    legend('Location', 'northoutside', 'Orientation', 'horizontal', 'FontSize', 8);

    % === 子图 2: 深度剖面示意 ===
    subplot(2, 1, 2);
    hold on;

    y_bot = -max([gpr.clutter_depth_range_m(2), ...
        max([gpr.targets.depth_m]) + max([gpr.targets.radius_m]) + 0.5]);

    xlim(x_lim);
    ylim([y_bot, gpr.antenna_height_m + 0.1]);

    % 地表
    plot(x_lim, [0 0], 'Color', [0.25 0.50 0.15], 'LineWidth', 2);

    % 杂波分布区
    fill([x_lim(1) x_lim(2) x_lim(2) x_lim(1)], ...
        [-gpr.clutter_depth_range_m(2) -gpr.clutter_depth_range_m(2) ...
         -gpr.clutter_depth_range_m(1) -gpr.clutter_depth_range_m(1)], ...
        [0.7 0.65 0.55], 'FaceAlpha', 0.25, 'EdgeColor', 'none', ...
        'DisplayName', '杂波分布区');

    % 天线轨迹
    plot(scan_lim, [gpr.antenna_height_m gpr.antenna_height_m], ...
        'b--', 'LineWidth', 1, 'DisplayName', '天线高度');
    plot(scan_x, gpr.antenna_height_m, 'rv', 'MarkerSize', 10, ...
        'MarkerFaceColor', 'r', ...
        'DisplayName', 'A扫天线位置');

    % 目标作为椭圆投影
    theta = linspace(0, 2*pi, 40);
    for k = 1:numel(gpr.targets)
        tgt = gpr.targets(k);
        col = pcolors{min(k, numel(pcolors))};
        rx = tgt.radius_m * cos(theta);
        ry = tgt.radius_m * sin(theta) * 0.35;
        fill(tgt.center_x_m + rx, -tgt.depth_m + ry, col, ...
            'FaceAlpha', 0.5, 'EdgeColor', col*0.6, 'LineWidth', 1.5);
        text(tgt.center_x_m, -tgt.depth_m - tgt.radius_m - 0.2, ...
            sprintf('T%d', k), 'FontSize', 9, ...
            'FontWeight', 'bold', 'Color', col, 'HorizontalAlignment', 'center');
    end

    xlabel('水平位置 (m)');
    ylabel('深度 / 高度 (m)');
    title(sprintf('扫描剖面 | 深度方向 (v=%.2f m/ns)', ...
        299792458 / sqrt(gpr.soil_eps_r) / 1e9), 'FontSize', 12);
    grid on;
    legend('Location', 'northoutside', 'Orientation', 'horizontal', 'FontSize', 8);

    save_figure(fig, 'ex18_scan_plan', opts);
end

%% ========================================================================
function pipe_colors = pipe_colors()
    pipe_colors = {[0.85 0.20 0.20], [0.85 0.15 0.55], [0.20 0.60 0.85]};
end

function save_figure(fig, basename, opts)
    if ~opts.SaveFigs
        return;
    end
    if exist(opts.OutputDir, 'dir') ~= 7
        mkdir(opts.OutputDir);
    end
    fname = fullfile(opts.OutputDir, [basename '.png']);
    try
        exportgraphics(fig, fname, 'Resolution', 160);
    catch
        saveas(fig, fname);
    end
    fprintf('  Saved: %s\n', fname);
end

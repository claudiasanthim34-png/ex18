function patch_ex18_dsp_scope_to_vector()
%PATCH_EX18_DSP_SCOPE_TO_VECTOR 将 Scope_DSP_AScan 替换为 Array Plot。
%
%   DSP System Toolbox 的 Array Plot 专为显示帧/向量信号设计，
%   横轴为元素序号（对应 IFFT bin / 时延），纵轴为幅度。
%   天然适合显示 A-scan 波形。
%
%   用法:
%     patch_ex18_dsp_scope_to_vector

    work_dir = fileparts(mfilename('fullpath'));
    ex18_dir = fileparts(work_dir);
    model_name = 'ex18_sfw_top';
    model_file = fullfile(ex18_dir, [model_name '.slx']);

    % --- 备份 ---
    output_dir = fullfile(work_dir, 'output');
    if exist(output_dir, 'dir') ~= 7, mkdir(output_dir); end
    backup_file = fullfile(output_dir, ...
        [model_name '_backup_before_arrayplot.slx']);
    if bdIsLoaded(model_name), close_system(model_name, 1); end
    load_system(model_file);
    copyfile(model_file, backup_file);
    fprintf('Backup: %s\n', backup_file);

    % --- 检查 DSP_Abs ---
    abs_path = [model_name '/DSP_Abs'];
    try
        abs_pos = get_param(abs_path, 'Position');
    catch
        fprintf('DSP_Abs does not exist. Run patch_ex18_dsp_ascan first.\n');
        close_system(model_name, 0);
        return;
    end

    % --- 删除旧 Scope 及连线 ---
    old_scope = [model_name '/Scope_DSP_AScan'];
    try
        ph = get_param(old_scope, 'PortHandles');
        for i = 1:numel(ph.Inport)
            lh = get_param(ph.Inport(i), 'Line');
            if lh > 0, delete_line(lh); end
        end
        delete_block(old_scope);
        fprintf('Deleted old Scope_DSP_AScan.\n');
    catch ME
        fprintf('Skip delete old scope: %s\n', ME.message);
    end

    % --- 添加 Array Plot ---
    plot_lib = 'dspsnks4/Array Plot';
    new_scope_path = [model_name '/Scope_DSP_AScan'];
    try
        add_block(plot_lib, new_scope_path);
    catch ME
        fprintf('Failed to add Array Plot: %s\n', ME.message);
        close_system(model_name, 0);
        return;
    end

    % 放在 DSP_Abs 右侧
    scope_x = abs_pos(3) + 40;
    scope_y = abs_pos(2) - 10;
    set_param(new_scope_path, 'Position', ...
        [scope_x scope_y scope_x+250 scope_y+250]);

    % --- 配置 Array Plot ---
    set_param(new_scope_path, ...
        'YLimits', '[-2, 2]', ...
        'ShowGrid', 'on', ...
        'XLabel', 'IFFT Bin (zero-padded to 4096)', ...
        'YLabel', 'Amplitude', ...
        'Title', 'DSP A-Scan');

    fprintf('Array Plot configured:\n');
    fprintf('  X-axis: Element index (1-4096) -> IFFT bin -> delay\n');
    fprintf('  Y-axis: Amplitude\n');
    fprintf('  Each frame update = one complete A-scan waveform\n');

    % --- 连线 ---
    try
        add_line(model_name, 'DSP_Abs/1', 'Scope_DSP_AScan/1', ...
            'autorouting', 'on');
        fprintf('Wired: DSP_Abs/1 -> Scope_DSP_AScan/1\n');
    catch ME
        fprintf('Wiring failed: %s\n', ME.message);
    end

    % --- 保存 ---
    set_param(model_name, 'Dirty', 'off');
    save_system(model_name, model_file);
    fprintf('Model saved: %s\n', model_file);
    close_system(model_name, 0);
    fprintf('Done.\n');
end

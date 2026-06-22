function patch_ex18_rx_bpf_lna()
%PATCH_EX18_RX_BPF_LNA 在 RX_Antenna 之后插入带通滤波器 + 低噪声放大器。
%
%   新增链路: RX_Antenna → RX_BPF → RX_LNA → RX_Down_Mixer (端口1)
%   保留:     RX_Antenna → Log_RX_Antenna (不变)
%
%   修改前会自动备份 ex18_sfw_top.slx 到 patches/output/ 目录。

    work_dir = fileparts(mfilename('fullpath'));
    ex18_dir = fileparts(work_dir);
    model_name = 'ex18_sfw_top';
    model_file = fullfile(ex18_dir, [model_name '.slx']);

    % === 备份模型 ===
    output_dir = fullfile(work_dir, 'output');
    if exist(output_dir, 'dir') ~= 7
        mkdir(output_dir);
    end
    backup_file = fullfile(output_dir, [model_name '_backup_before_bpf_lna.slx']);

    if bdIsLoaded(model_name)
        close_system(model_name, 0);
    end
    load_system(model_file);
    fprintf('备份已保存: %s\n', backup_file);
    copyfile(model_file, backup_file);

    % === 检查是否已打过补丁 ===
    existing = find_system(model_name, 'SearchDepth', 1, 'Name', 'RX_BPF');
    if ~isempty(existing)
        fprintf('RX_BPF 已存在，跳过补丁。\n');
        close_system(model_name, 0);
        return;
    end

    % === 1. 添加 RX_BPF（带通滤波器）===
    % 放在 RX_Antenna 和 RX_Down_Mixer 之间
    pos_bpf = [1245 385 1370 455];
    add_block('simulink/Discrete/Discrete Filter', [model_name '/RX_BPF'], ...
        'Numerator',   'rx_bpf_num', ...
        'Denominator', 'rx_bpf_den', ...
        'InitialStates', '0', ...
        'SampleTime',  'sfw_sample_s', ...
        'Position',    pos_bpf);

    % === 2. 添加 RX_LNA（低噪声放大器，用增益块建模）===
    pos_lna = [1395 395 1445 445];
    add_block('simulink/Math Operations/Gain', [model_name '/RX_LNA'], ...
        'Gain',       'rx_lna_gain', ...
        'SampleTime', 'sfw_sample_s', ...
        'Position',   pos_lna);

    % === 3. 添加日志块记录 LNA 输出 ===
    pos_log = [1605 550 1705 580];
    add_block('simulink/Sinks/To Workspace', [model_name '/Log_RX_LNA'], ...
        'VariableName', 'rx_lna_log', ...
        'SaveFormat', 'Structure With Time', ...
        'Position', pos_log);

    % === 4. 删除旧连线: RX_Antenna → RX_Down_Mixer（端口1）===
    src = get_param([model_name '/RX_Antenna'], 'Handle');
    dst = get_param([model_name '/RX_Down_Mixer'], 'Handle');
    lines = get_param([model_name '/RX_Antenna'], 'LineHandles');
    for i = 1:numel(lines.Outport)
        if ~isempty(lines.Outport(i)) && ishandle(lines.Outport(i))
            dst_blk = get_param(lines.Outport(i), 'DstBlockHandle');
            if any(dst_blk == dst)
                delete_line(lines.Outport(i));
                fprintf('已移除旧连线: RX_Antenna -> RX_Down_Mixer\n');
                break;
            end
        end
    end

    % === 5. 建立新连线 ===
    add_line(model_name, 'RX_Antenna/1', 'RX_BPF/1', 'autorouting', 'on');
    add_line(model_name, 'RX_BPF/1', 'RX_LNA/1', 'autorouting', 'on');
    add_line(model_name, 'RX_LNA/1', 'RX_Down_Mixer/1', 'autorouting', 'on');
    add_line(model_name, 'RX_LNA/1', 'Log_RX_LNA/1', 'autorouting', 'on');

    fprintf('RX_BPF + RX_LNA 已添加: RX_Antenna -> RX_BPF -> RX_LNA -> RX_Down_Mixer\n');

    % === 6. 保存模型 ===
    save_system(model_name);
    fprintf('模型已保存: %s.slx\n', model_name);
    close_system(model_name, 0);
end

function patch_ex18_dsp_ascan()
%PATCH_EX18_DSP_ASCAN 在 IQ 基带输出后添加 DSP A-scan 管线。
%
%   流水线: IQ_LPF_Complex → ZOH → Buffer → Win → BGS → IFFT → Abs → Scope/Log
%
%   ZOH(零阶保持) — 以低采样率抽取 IQ 样本（每 PRI 1 点）
%   Buffer      — 收集 501 个频点复样本为一帧
%   Win         — Hann 加窗（抑制 IFFT 旁瓣）
%   BGS         — 背景扣除（减去土壤模型背景，亮出目标回波）
%   IFFT(4096)  — 频域到时域转换
%   Abs         — 复数幅度
%   Scope/Log   — 波形显示 / 保存

    work_dir = fileparts(mfilename('fullpath'));
    ex18_dir = fileparts(work_dir);
    model_name = 'ex18_sfw_top';
    model_file = fullfile(ex18_dir, [model_name '.slx']);

    % --- 备份 ---
    output_dir = fullfile(work_dir, 'output');
    if exist(output_dir, 'dir') ~= 7, mkdir(output_dir); end
    backup_file = fullfile(output_dir, [model_name '_backup_before_dsp_ascan.slx']);
    if bdIsLoaded(model_name), close_system(model_name, 1); end
    load_system(model_file);
    copyfile(model_file, backup_file);
    fprintf('备份: %s\n', backup_file);

    if ~isempty(find_system(model_name, 'SearchDepth', 1, 'Name', 'DSP_Buffer'))
        fprintf('DSP A-scan 管线已存在，跳过。\n');
        close_system(model_name, 0);
        return;
    end

    if ~evalin('base', 'exist(''dsp_samples_per_pri'', ''var'')')
        setup_ex18_sfw();
    end

    x0 = 2500;  y0 = 420;

    % ========================================================================
    % 1. 零阶保持 — 以 sfw_sample_s * samples_per_pri 为周期重采样
    %    只保留每个 PRI 中的 1 个点（位于 PRI 后半段稳定区）
    % ========================================================================
    pri_sample_time = evalin('base', 'sfw_sample_s * dsp_samples_per_pri');
    add_block('simulink/Discrete/Zero-Order Hold', [model_name '/DSP_ZOH'], ...
        'SampleTime', num2str(pri_sample_time), ...
        'Position', [x0 y0 x0+70 y0+50]);
    x0 = x0 + 130;
    fprintf('  + DSP_ZOH (Ts=%.3g us)\n', pri_sample_time*1e6);

    % ========================================================================
    % 2. Buffer — 501 帧累积
    % ========================================================================
    add_block('dspbuff3/Buffer', [model_name '/DSP_Buffer'], ...
        'N', 'numel(sfw_freq_hz)', ...
        'ic', '0', ...
        'OverlapPercent', '0', ...
        'Position', [x0 y0 x0+70 y0+50]);
    x0 = x0 + 130;
    fprintf('  + DSP_Buffer (尺寸=501)\n');

    % ========================================================================
    % 4. Hann 窗
    % ========================================================================
    add_block('simulink/Math Operations/Product', [model_name '/DSP_Window'], ...
        'Multiplication', 'Element-wise(.*)', ...
        'Inputs', '2', ...
        'Position', [x0 y0+5 x0+65 y0+45]);
    add_block('simulink/Sources/Constant', [model_name '/DSP_WindowCoef'], ...
        'Value', 'dsp_ascan_window', ...
        'SampleTime', 'inf', ...
        'Position', [x0-30 y0-65 x0+50 y0-25]);
    x0 = x0 + 130;

    % ========================================================================
    % 5. 背景扣除
    % ========================================================================
    add_block('simulink/Math Operations/Add', [model_name '/DSP_BGS_Subtract'], ...
        'Inputs', '+-', ...
        'IconShape', 'rectangular', ...
        'Position', [x0 y0+5 x0+65 y0+45]);
    add_block('simulink/Sources/Constant', [model_name '/DSP_Background'], ...
        'Value', 'dsp_background_response', ...
        'SampleTime', 'inf', ...
        'Position', [x0-30 y0-65 x0+50 y0-25]);
    x0 = x0 + 130;

    % ========================================================================
    % 6. IFFT 4096 点
    % ========================================================================
    add_block('dspxfrm3/IFFT', [model_name '/DSP_IFFT'], ...
        'FFTLength', '4096', ...
        'Normalize', 'off', ...
        'Position', [x0 y0 x0+70 y0+50]);
    x0 = x0 + 130;

    % ========================================================================
    % 7. Abs — |complex|
    % ========================================================================
    add_block('simulink/Math Operations/Abs', [model_name '/DSP_Abs'], ...
        'Position', [x0 y0+5 x0+65 y0+45]);
    x0 = x0 + 130;

    % ========================================================================
    % 8. Scope + Log (先删除已存在块，避免冲突)
    % ========================================================================
    for blk = {'Scope_DSP_AScan', 'Log_DSP_AScan'}
        bp = [model_name '/' blk{1}];
        try
            ph = get_param(bp, 'PortHandles');
            for j = 1:numel(ph.Inport)
                lh = get_param(ph.Inport(j), 'Line');
                if lh > 0, delete_line(lh); end
            end
            delete_block(bp);
        catch
        end
    end
    add_block('simulink/Sinks/Scope', [model_name '/Scope_DSP_AScan'], ...
        'Position', [x0 y0-10 x0+50 y0+30]);
    add_block('simulink/Sinks/To Workspace', [model_name '/Log_DSP_AScan'], ...
        'VariableName', 'dsp_ascan_log', ...
        'SaveFormat', 'Structure With Time', ...
        'Position', [x0 y0+40 x0+120 y0+70]);
    fprintf('  + DSP_Window + BGS + IFFT + Abs + Scope/Log\n');

    % ========================================================================
    % 连线
    % ========================================================================
    add_line(model_name, 'IQ_LPF_Complex/1',   'DSP_ZOH/1',           'autorouting', 'on');
    add_line(model_name, 'DSP_ZOH/1',           'DSP_Buffer/1',        'autorouting', 'on');
    add_line(model_name, 'DSP_Buffer/1',        'DSP_Window/1',        'autorouting', 'on');
    add_line(model_name, 'DSP_WindowCoef/1',    'DSP_Window/2',        'autorouting', 'on');
    add_line(model_name, 'DSP_Window/1',        'DSP_BGS_Subtract/1',  'autorouting', 'on');
    add_line(model_name, 'DSP_Background/1',    'DSP_BGS_Subtract/2',  'autorouting', 'on');
    add_line(model_name, 'DSP_BGS_Subtract/1',  'DSP_IFFT/1',          'autorouting', 'on');
    add_line(model_name, 'DSP_IFFT/1',          'DSP_Abs/1',           'autorouting', 'on');
    add_line(model_name, 'DSP_Abs/1',           'Scope_DSP_AScan/1',   'autorouting', 'on');
    add_line(model_name, 'DSP_Abs/1',           'Log_DSP_AScan/1',     'autorouting', 'on');
    fprintf('连线完成: IQ → ZOH → Buffer → Win → BGS → IFFT → Abs → Scope/Log\n');

    set_param(model_name, 'Dirty', 'off');
    save_system(model_name);
    fprintf('模型已保存: %s.slx\n', model_name);
    close_system(model_name, 0);
end

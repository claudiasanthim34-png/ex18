function restructure_iq_demod()
model = 'ex18_sfw_top';
load_system(model);

% ---- 1. 断开并删除旧块 ----
old_blocks = {'IQ_Complex_Mixer', 'IQ_LO_Complex', 'IQ_LPF_Complex', ...
              'IQ_Mixer_I', 'IQ_Mixer_Q', 'IQ_LPF_I', 'IQ_LPF_Q', 'IQ_Combine', ...
              'IQ_Compx_Mixer', 'IQ_Split'};
for i = 1:numel(old_blocks)
    bp = [model '/' old_blocks{i}];
    try
        ph = get_param(bp, 'PortHandles');
        for j = 1:numel(ph.Inport)
            lh = get_param(ph.Inport(j), 'Line');
            if lh > 0, delete_line(lh); end
        end
        for j = 1:numel(ph.Outport)
            lh = get_param(ph.Outport(j), 'Line');
            if lh > 0, delete_line(lh); end
        end
        delete_block(bp);
        fprintf('Deleted: %s\n', bp);
    catch ME
        fprintf('Skip %s: %s\n', bp, ME.message);
    end
end

% ---- 2. 清掉下游块的旧连线 ----
out_blocks = {'Scope_RX_IQ_Baseband', 'Log_RX_IQ', 'Subsystem'};
for i = 1:numel(out_blocks)
    bp = [model '/' out_blocks{i}];
    try
        ph = get_param(bp, 'PortHandles');
        for j = 1:numel(ph.Inport)
            lh = get_param(ph.Inport(j), 'Line');
            if lh > 0, delete_line(lh); end
        end
    catch
    end
end

% ---- 3. 添加新块 ----
% 复数本振：cos - j*sin = exp(-j*ωt)
add_block('simulink/Math Operations/Real-Imag to Complex', [model '/IQ_LO_Complex'], ...
    'Position', [1340 555 1425 655]);

% 复数混频器：IF(complex) × LO(complex) = complex
add_block('simulink/Math Operations/Product', [model '/IQ_Compx_Mixer'], ...
    'Inputs', '**', 'Position', [1225 470 1280 530]);

% 复数 → 实部/虚部分解
add_block('simulink/Math Operations/Complex to Real-Imag', [model '/IQ_Split'], ...
    'Position', [1200 460 1295 540]);

% I 路 LPF
add_block('simulink/Discrete/Discrete FIR Filter', [model '/IQ_LPF_I'], ...
    'Coefficients', 'iq_lpf_num', 'InitialStates', '0', ...
    'SampleTime', 'sfw_sample_s', ...
    'InputProcessing', 'Elements as channels (sample based)', ...
    'Position', [1060 460 1170 520]);

% Q 路 LPF
add_block('simulink/Discrete/Discrete FIR Filter', [model '/IQ_LPF_Q'], ...
    'Coefficients', 'iq_lpf_num', 'InitialStates', '0', ...
    'SampleTime', 'sfw_sample_s', ...
    'InputProcessing', 'Elements as channels (sample based)', ...
    'Position', [1060 540 1170 600]);

% I/Q 合成复数 (I→Real, Q→Imag)
add_block('simulink/Math Operations/Real-Imag to Complex', [model '/IQ_Combine'], ...
    'Position', [910 480 995 580]);

fprintf('New blocks: IQ_Compx_Mixer, IQ_Split, IQ_LPF_I/Q, IQ_Combine\n');

% ---- 4. 连线 ----
lines = {
    % 复数本振合成
    'IQ_LO_cos/1',       'IQ_LO_Complex/1';
    'IQ_LO_nsin/1',      'IQ_LO_Complex/2';
    % IF → 复数混频器
    'RX_Down_IF_BPF/1',  'IQ_Compx_Mixer/1';
    % 本振 → 混频器
    'IQ_LO_Complex/1',   'IQ_Compx_Mixer/2';
    % 混频器输出 → 复→实/虚分解
    'IQ_Compx_Mixer/1',  'IQ_Split/1';
    % 实部(I) → LPF_I
    'IQ_Split/1',        'IQ_LPF_I/1';
    % 虚部(Q) → LPF_Q
    'IQ_Split/2',        'IQ_LPF_Q/1';
    % LPF_I (I) → 复数合成 Real
    'IQ_LPF_I/1',        'IQ_Combine/1';
    % LPF_Q (Q) → 复数合成 Imag
    'IQ_LPF_Q/1',        'IQ_Combine/2';
    % 复数输出 → 下游
    'IQ_Combine/1',      'Scope_RX_IQ_Baseband/1';
    'IQ_Combine/1',      'Log_RX_IQ/1';
    'IQ_Combine/1',      'Subsystem/1';
};
for i = 1:size(lines, 1)
    try
        add_line(model, lines{i,1}, lines{i,2}, 'autorouting', 'on');
        fprintf('  %s -> %s OK\n', lines{i,1}, lines{i,2});
    catch ME
        fprintf('  %s -> %s FAIL: %s\n', lines{i,1}, lines{i,2}, ME.message);
    end
end

% ---- 5. 保存 ----
set_param(model, 'Dirty', 'off');
save_system(model);
fprintf('Model saved.\n');
close_system(model, 0);
fprintf('Done.\n');
end

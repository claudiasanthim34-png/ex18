function fix_iq_complex_demod()
    % 该函数用于自动修改 Simulink 模型，将原有的分离式 I/Q 解调替换为复数解调结构
    
    % --- 1. 定义模型名称与路径 ---
    model = 'ex18_sfw_top'; % Simulink 模型的名称
    model_file = fullfile('D:\work place\Matlab\ex18', [model '.slx']); % 模型的完整文件路径
    
    % 在后台加载模型（不打开可视化的模型窗口，提高脚本执行速度）
    load_system(model_file);
    
    % --- 2. 定义需要删除的旧模块 ---
    % 这些是原有分离式 I/Q 架构中的模块：实数转换、独立的 I/Q 混频器、独立的 I/Q 低通滤波器等
    old_blocks = {'IF_to_Real', 'Mixer_I', 'Mixer_Q', 'LPF_I', 'LPF_Q', ...
                  'Real-Imag_to_Complex', 'Final_LO_200MHz', 'Final_LO_200MHz_Q'};
    
    % --- 3. 删除与旧模块相连的信号线 ---
    % 在删除模块前，先清理与其连接的输入/输出信号线，避免留下悬空线 (broken links)
    for i = 1:numel(old_blocks)
        bp = [model '/' old_blocks{i}]; % 拼接完整的模块路径
        try
            % 获取模块的端口句柄 (PortHandles)
            ph = get_param(bp, 'PortHandles');
            
            % 遍历并删除连接到输入端口 (Inport) 的线
            for j = 1:numel(ph.Inport)
                lh = get_param(ph.Inport(j), 'Line'); % 获取连接线的句柄
                if lh > 0 % 如果句柄有效（存在连接线）
                    delete_line(lh);
                end
            end
            
            % 遍历并删除连接到输出端口 (Outport) 的线
            for j = 1:numel(ph.Outport)
                lh = get_param(ph.Outport(j), 'Line');
                if lh > 0
                    delete_line(lh);
                end
            end
        catch
            % 如果模块不存在或没有端口，捕获异常并忽略（继续执行）
        end
    end
    
    % --- 4. 删除旧模块 ---
    for i = 1:numel(old_blocks)
        bp = [model '/' old_blocks{i}];
        try
            delete_block(bp); % 执行删除操作
            fprintf('Deleted: %s\n', bp);
        catch ME
            % 如果删除失败（例如模块已经被删过），打印跳过信息及错误原因
            fprintf('Skip %s: %s\n', bp, ME.message);
        end
    end
    
    % --- 5. 添加新模块 (构建复数解调架构) ---
    
    % 5.1 添加复数乘法器 (Mixer)
    % 接受两个输入端口 ('**')，用于将中频信号与复数本振信号相乘
    add_block('simulink/Math Operations/Product', [model '/IQ_Complex_Mixer'], ...
        'Inputs', '**', 'Position', [2150 290 2200 350]);
    
    % 5.2 添加本振信号：I 路 (Cosine)
    % Simulink 的 Sine Wave 默认是 sin(wt)。设置相位 Phase 为 pi/2，即 sin(wt + pi/2) = cos(wt)
    add_block('simulink/Sources/Sine Wave', [model '/IQ_LO_cos'], ...
        'Amplitude', '1', 'Bias', '0', 'Frequency', '2*pi*iq_lo_hz', ...
        'Phase', 'pi/2', 'SampleTime', 'sfw_sample_s', ...
        'Position', [2160 390 2310 430]);
    
    % 5.3 添加本振信号：Q 路 (-Sine)
    % 设置相位 Phase 为 pi，即 sin(wt + pi) = -sin(wt)。
    % 结合 I 路，这构建了一个负频率的复本振信号 $e^{-j\omega t} = \cos(\omega t) - j\sin(\omega t)$，用于下变频
    add_block('simulink/Sources/Sine Wave', [model '/IQ_LO_nsin'], ...
        'Amplitude', '1', 'Bias', '0', 'Frequency', '2*pi*iq_lo_hz', ...
        'Phase', 'pi', 'SampleTime', 'sfw_sample_s', ...
        'Position', [2160 460 2310 500]);
    
    % 5.4 添加实部/虚部转复数模块
    % 将上述的 cos(wt) 和 -sin(wt) 组合成一个复数信号传入混频器
    add_block('simulink/Math Operations/Real-Imag to Complex', [model '/IQ_LO_Complex'], ...
        'Position', [2360 400 2430 490]);
    
    % 5.5 添加复数低通滤波器 (Discrete FIR Filter)
    % 用于滤除混频后产生的高频(和频)分量，保留基带(差频)分量。
    % 滤波器系数从工作区变量 'iq_lpf_num' 获取
    add_block('simulink/Discrete/Discrete FIR Filter', [model '/IQ_LPF_Complex'], ...
        'Coefficients', 'iq_lpf_num', 'InitialStates', '0', ...
        'SampleTime', 'sfw_sample_s', ...
        'InputProcessing', 'Elements as channels (sample based)', ...
        'Position', [2280 280 2550 380]);
    
    fprintf('All new blocks added.\n');
    
    % --- 6. 自动连线 ---
    % 定义需要连接的起点和终点列表 {'源模块/端口号', '目标模块/端口号'}
    lines_to_add = {
        'RX_Down_IF_BPF/1',  'IQ_Complex_Mixer/1'; % 中频信号 -> 混频器输入 1
        'IQ_LO_cos/1',       'IQ_LO_Complex/1';    % Cos 信号 -> 复数合成器实部 (I)
        'IQ_LO_nsin/1',      'IQ_LO_Complex/2';    % -Sin 信号 -> 复数合成器虚部 (Q)
        'IQ_LO_Complex/1',   'IQ_Complex_Mixer/2'; % 复数本振 -> 混频器输入 2
        'IQ_Complex_Mixer/1','IQ_LPF_Complex/1';   % 混频输出 -> 复数低通滤波器
        'IQ_LPF_Complex/1',  'Scope_RX_IQ_Baseband/1'; % 滤波后输出 -> 示波器观察
        'IQ_LPF_Complex/1',  'Log_RX_IQ/1';        % 滤波后输出 -> 数据记录模块
    };
    
    % 遍历列表并尝试添加连线
    for i = 1:size(lines_to_add, 1)
        try
            % 'autorouting', 'on' 让 Simulink 自动计算走线路径，避免线条重叠杂乱
            add_line(model, lines_to_add{i,1}, lines_to_add{i,2}, 'autorouting', 'on');
            fprintf('OK: %s -> %s\n', lines_to_add{i,1}, lines_to_add{i,2});
        catch ME
            % 捕获连线错误（如端口不存在或已被占用）
            fprintf('FAIL: %s -> %s  [%s]\n', lines_to_add{i,1}, lines_to_add{i,2}, ME.message);
        end
    end
    
    % --- 7. 保存并关闭模型 ---
    save_system(model, model_file); % 保存修改后的模型
    fprintf('Saved: %s\n', model_file);
    close_system(model, 1); % 从内存中关闭模型并确认保存修改
    fprintf('Done.\n');
end
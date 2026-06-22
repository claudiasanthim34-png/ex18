function fix_iq_complex_demod()
    model = 'ex18_sfw_top';
    model_file = fullfile('D:\work place\Matlab\ex18', [model '.slx']);
    
    load_system(model_file);
    
    % Delete old lines to/from the blocks we're removing
    old_blocks = {'IF_to_Real', 'Mixer_I', 'Mixer_Q', 'LPF_I', 'LPF_Q', ...
                  'Real-Imag_to_Complex', 'Final_LO_200MHz', 'Final_LO_200MHz_Q'};
    
    % First, delete all lines connected to these blocks
    for i = 1:numel(old_blocks)
        bp = [model '/' old_blocks{i}];
        try
            ph = get_param(bp, 'PortHandles');
            for j = 1:numel(ph.Inport)
                lh = get_param(ph.Inport(j), 'Line');
                if lh > 0
                    delete_line(lh);
                end
            end
            for j = 1:numel(ph.Outport)
                lh = get_param(ph.Outport(j), 'Line');
                if lh > 0
                    delete_line(lh);
                end
            end
        catch
        end
    end
    
    % Now delete the blocks
    for i = 1:numel(old_blocks)
        bp = [model '/' old_blocks{i}];
        try
            delete_block(bp);
            fprintf('Deleted: %s\n', bp);
        catch ME
            fprintf('Skip %s: %s\n', bp, ME.message);
        end
    end
    
    % Add new blocks
    add_block('simulink/Math Operations/Product', [model '/IQ_Complex_Mixer'], ...
        'Inputs', '**', 'Position', [2150 290 2200 350]);
    
    add_block('simulink/Sources/Sine Wave', [model '/IQ_LO_cos'], ...
        'Amplitude', '1', 'Bias', '0', 'Frequency', '2*pi*iq_lo_hz', ...
        'Phase', 'pi/2', 'SampleTime', 'sfw_sample_s', ...
        'Position', [2160 390 2310 430]);
    
    add_block('simulink/Sources/Sine Wave', [model '/IQ_LO_nsin'], ...
        'Amplitude', '1', 'Bias', '0', 'Frequency', '2*pi*iq_lo_hz', ...
        'Phase', 'pi', 'SampleTime', 'sfw_sample_s', ...
        'Position', [2160 460 2310 500]);
    
    add_block('simulink/Math Operations/Real-Imag to Complex', [model '/IQ_LO_Complex'], ...
        'Position', [2360 400 2430 490]);
    
    add_block('simulink/Discrete/Discrete FIR Filter', [model '/IQ_LPF_Complex'], ...
        'Coefficients', 'iq_lpf_num', 'InitialStates', '0', ...
        'SampleTime', 'sfw_sample_s', ...
        'InputProcessing', 'Elements as channels (sample based)', ...
        'Position', [2280 280 2550 380]);
    
    fprintf('All new blocks added.\n');
    
    % Add lines - use try/catch for each
    lines_to_add = {
        'RX_Down_IF_BPF/1', 'IQ_Complex_Mixer/1';
        'IQ_LO_cos/1',       'IQ_LO_Complex/1';
        'IQ_LO_nsin/1',      'IQ_LO_Complex/2';
        'IQ_LO_Complex/1',   'IQ_Complex_Mixer/2';
        'IQ_Complex_Mixer/1','IQ_LPF_Complex/1';
        'IQ_LPF_Complex/1',  'Scope_RX_IQ_Baseband/1';
        'IQ_LPF_Complex/1',  'Log_RX_IQ/1';
    };
    
    for i = 1:size(lines_to_add, 1)
        try
            add_line(model, lines_to_add{i,1}, lines_to_add{i,2}, 'autorouting', 'on');
            fprintf('OK: %s -> %s\n', lines_to_add{i,1}, lines_to_add{i,2});
        catch ME
            fprintf('FAIL: %s -> %s  [%s]\n', lines_to_add{i,1}, lines_to_add{i,2}, ME.message);
        end
    end
    
    save_system(model, model_file);
    fprintf('Saved: %s\n', model_file);
    close_system(model, 1);
    fprintf('Done.\n');
end

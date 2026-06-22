function ex18_filter_dialog(block_path)
%EX18_FILTER_DIALOG Popup dialog to edit filter cutoff on double-click.
[~, block_name] = fileparts(block_path);

switch block_name
    case 'Tap_Up_BPF'
        prompt = {'Low cutoff (MHz):', 'High cutoff (MHz):'};
        dlgtitle = 'Tap_Up_BPF - Bandpass Filter';
        try
            hz = evalin('base', 'tap_up_bpf_hz');
            def = {num2str(hz(1)/1e6), num2str(hz(2)/1e6)};
        catch
            def = {'210', '380'};
        end
        answer = inputdlg(prompt, dlgtitle, 1, def);
        if isempty(answer), return; end
        f_low = str2double(answer{1}) * 1e6;
        f_high = str2double(answer{2}) * 1e6;
        fs = evalin('base', 'sfw_fs_hz');
        try order = evalin('base', 'tap_up_bpf_order'); catch; order = 8192; end
        [num, den] = ex18_design_fir_bandpass(order, [f_low f_high], fs, 'Tap_Up_BPF:BadPassband');
        assignin('base', 'tap_up_bpf_num', num);
        assignin('base', 'tap_up_bpf_den', den);
        assignin('base', 'tap_up_bpf_hz', [f_low f_high]);
        fprintf('Tap_Up_BPF: %.1f - %.1f MHz\n', f_low/1e6, f_high/1e6);

    case 'RX_Down_IF_BPF'
        prompt = {'Center freq (MHz):', 'Half BW (MHz):'};
        dlgtitle = 'RX_Down_IF_BPF - Bandpass Filter';
        try
            fc = evalin('base', 'rx_down_if_center_hz')/1e6;
            bw = evalin('base', 'rx_down_if_half_bw_hz')/1e6;
            def = {num2str(fc), num2str(bw)};
        catch
            def = {'200', '10'};
        end
        answer = inputdlg(prompt, dlgtitle, 1, def);
        if isempty(answer), return; end
        center = str2double(answer{1}) * 1e6;
        half_bw = str2double(answer{2}) * 1e6;
        f_low = center - half_bw;
        f_high = center + half_bw;
        fs = evalin('base', 'sfw_fs_hz');
        try order = evalin('base', 'rx_down_if_bpf_order'); catch; order = 8192; end
        [num, den] = ex18_design_fir_bandpass(order, [f_low f_high], fs, 'RX_Down_IF_BPF:BadPassband');
        assignin('base', 'rx_down_if_bpf_num', num);
        assignin('base', 'rx_down_if_bpf_den', den);
        assignin('base', 'rx_down_if_center_hz', center);
        assignin('base', 'rx_down_if_half_bw_hz', half_bw);
        assignin('base', 'rx_down_if_bpf_hz', [f_low f_high]);
        fprintf('RX_Down_IF_BPF: %.1f +/- %.1f MHz\n', center/1e6, half_bw/1e6);

    case {'LPF_I', 'LPF_Q'}
        prompt = {'Cutoff freq (MHz):'};
        dlgtitle = [block_name ' - Lowpass Filter'];
        try
            fc = evalin('base', 'iq_lpf_cutoff_hz')/1e6;
            def = {num2str(fc)};
        catch
            def = {'10'};
        end
        answer = inputdlg(prompt, dlgtitle, 1, def);
        if isempty(answer), return; end
        cutoff_hz = str2double(answer{1}) * 1e6;
        fs = evalin('base', 'sfw_fs_hz');
        try order = evalin('base', 'iq_lpf_order'); catch; order = 1024; end
        [num, den] = ex18_design_fir_lowpass(order, cutoff_hz, fs);
        assignin('base', 'iq_lpf_num', num);
        assignin('base', 'iq_lpf_cutoff_hz', cutoff_hz);
        fprintf('%s: cutoff %.1f MHz\n', block_name, cutoff_hz/1e6);
end
end

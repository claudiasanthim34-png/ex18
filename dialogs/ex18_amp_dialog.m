function ex18_amp_dialog(block_path)
%EX18_AMP_DIALOG Popup dialog to edit amplifier gain on double-click.
[~, block_name] = fileparts(block_path);

switch block_name
    case 'RF_VGA'
        prompt = {'Gain (dB):'};
        dlgtitle = 'RF_VGA - Amplifier';
        try
            g = evalin('base', 'rf_vga_gain_db');
            def = {num2str(g)};
        catch
            def = {'0'};
        end
        answer = inputdlg(prompt, dlgtitle, 1, def);
        if isempty(answer), return; end
        gain_db = str2double(answer{1});
        assignin('base', 'rf_vga_gain_db', gain_db);
        set_param(block_path, 'DataSource', 'Gain and noise data');
        set_param(block_path, 'Gain', num2str(gain_db));
        fprintf('RF_VGA gain set to %.1f dB\n', gain_db);

    case 'RF_PA'
        prompt = {'Gain (dB):'};
        dlgtitle = 'RF_PA - Amplifier';
        try
            g = evalin('base', 'rf_pa_gain_db');
            def = {num2str(g)};
        catch
            def = {'10'};
        end
        answer = inputdlg(prompt, dlgtitle, 1, def);
        if isempty(answer), return; end
        gain_db = str2double(answer{1});
        assignin('base', 'rf_pa_gain_db', gain_db);
        set_param(block_path, 'DataSource', 'Gain and noise data');
        set_param(block_path, 'Gain', num2str(gain_db));
        fprintf('RF_PA gain set to %.1f dB\n', gain_db);
end
end

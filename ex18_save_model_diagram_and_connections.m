function files = ex18_save_model_diagram_and_connections(varargin)
%EX18_SAVE_MODEL_DIAGRAM_AND_CONNECTIONS 保存 ex18 顶层模型图和连线清单。
%
%   files = ex18_save_model_diagram_and_connections()
%   将当前 ex18_sfw_top 顶层电路图导出为 PNG，并把顶层 blocks、line
%   connections、PortConnectivity 清单保存到 output 目录。
%
%   说明：
%   - 如果在已经打开 ex18_sfw_top 的 MATLAB 会话中运行，本函数导出当前内存中
%     的模型状态，包括尚未另存为新文件但已经在当前会话中存在的连线/模块。
%   - 如果在批处理 MATLAB 中运行，本函数会从磁盘加载 ex18_sfw_top.slx，导出
%     磁盘上已保存的模型状态。
%   - 默认不调用 save_system，不会主动保存或覆盖 .slx。

parser = inputParser;
parser.addParameter('Model', 'ex18_sfw_top', @(x) ischar(x) || isstring(x));
parser.addParameter('OutputDir', fullfile(fileparts(mfilename('fullpath')), 'output'), ...
    @(x) ischar(x) || isstring(x));
parser.addParameter('Timestamp', datestr(now, 'yyyymmdd_HHMMSS'), ...
    @(x) ischar(x) || isstring(x));
parser.addParameter('SaveModel', false, @(x) islogical(x) || isnumeric(x));
parser.parse(varargin{:});

opts = parser.Results;
model = char(opts.Model);
output_dir = char(opts.OutputDir);
timestamp = char(opts.Timestamp);

if exist(output_dir, 'dir') ~= 7
    mkdir(output_dir);
end

model_file = fullfile(fileparts(mfilename('fullpath')), [model '.slx']);
if ~bdIsLoaded(model)
    load_system(model_file);
end

if logical(opts.SaveModel)
    save_system(model);
end

prefix = fullfile(output_dir, [model '_' timestamp]);
files = struct();
files.diagram_png = [prefix '_diagram.png'];
files.blocks_csv = [prefix '_blocks.csv'];
files.lines_csv = [prefix '_line_connections.csv'];
files.port_connectivity_csv = [prefix '_port_connectivity.csv'];
files.snapshot_mat = [prefix '_snapshot.mat'];

export_model_diagram(model, files.diagram_png);
block_table = collect_block_table(model);
line_table = collect_line_table(model);
port_table = collect_port_connectivity_table(model);

writetable(block_table, files.blocks_csv);
writetable(line_table, files.lines_csv);
writetable(port_table, files.port_connectivity_csv);
save(files.snapshot_mat, 'model', 'timestamp', 'block_table', 'line_table', 'port_table');

fprintf('Saved ex18 model diagram and connection snapshot:\n');
fprintf('  Diagram: %s\n', files.diagram_png);
fprintf('  Blocks:  %s\n', files.blocks_csv);
fprintf('  Lines:   %s\n', files.lines_csv);
fprintf('  Ports:   %s\n', files.port_connectivity_csv);
fprintf('  MAT:     %s\n', files.snapshot_mat);
end

function export_model_diagram(model, png_file)
%EXPORT_MODEL_DIAGRAM 导出当前顶层模型图。
%   优先使用 Simulink.BlockDiagram.exportToImage；如果该接口不可用或失败，
%   则退回 open_system + print。
try
    Simulink.BlockDiagram.exportToImage(model, png_file);
catch
    open_system(model);
    try
        set_param(model, 'ZoomFactor', 'FitSystem');
    catch
    end
    print(['-s' model], '-dpng', '-r200', png_file);
end
end

function block_table = collect_block_table(model)
blocks = find_system(model, 'SearchDepth', 1, 'Type', 'Block');

rows = cell(numel(blocks), 6);
for k = 1:numel(blocks)
    block = blocks{k};
    rows{k, 1} = block;
    rows{k, 2} = get_safe(block, 'Name');
    rows{k, 3} = get_safe(block, 'BlockType');
    rows{k, 4} = get_safe(block, 'MaskType');
    rows{k, 5} = get_safe(block, 'ReferenceBlock');
    rows{k, 6} = mat2str(get_param(block, 'Position'));
end

block_table = cell2table(rows, 'VariableNames', ...
    {'FullPath', 'Name', 'BlockType', 'MaskType', 'ReferenceBlock', 'Position'});
end

function line_table = collect_line_table(model)
lines = find_system(model, 'SearchDepth', 1, 'FindAll', 'on', 'Type', 'line');

rows = {};
for k = 1:numel(lines)
    line = lines(k);
    src_block = get_param(line, 'SrcBlockHandle');
    src_port = get_param(line, 'SrcPortHandle');
    dst_blocks = get_param(line, 'DstBlockHandle');
    dst_ports = get_param(line, 'DstPortHandle');
    line_name = get_safe(line, 'Name');

    if isempty(dst_blocks)
        rows(end + 1, :) = {line_name, handle_name(src_block), port_name(src_port), '', ''}; %#ok<AGROW>
        continue;
    end

    for idx = 1:numel(dst_blocks)
        dst_port = -1;
        if idx <= numel(dst_ports)
            dst_port = dst_ports(idx);
        end
        rows(end + 1, :) = {line_name, handle_name(src_block), port_name(src_port), ...
            handle_name(dst_blocks(idx)), port_name(dst_port)}; %#ok<AGROW>
    end
end

if isempty(rows)
    rows = cell(0, 5);
end

line_table = cell2table(rows, 'VariableNames', ...
    {'LineName', 'SourceBlock', 'SourcePort', 'DestinationBlock', 'DestinationPort'});
end

function port_table = collect_port_connectivity_table(model)
blocks = find_system(model, 'SearchDepth', 1, 'Type', 'Block');

rows = {};
for k = 1:numel(blocks)
    block = blocks{k};
    try
        pc = get_param(block, 'PortConnectivity');
    catch
        continue;
    end

    for p = 1:numel(pc)
        src = '';
        if ~isempty(pc(p).SrcBlock) && pc(p).SrcBlock ~= -1
            src = handle_name(pc(p).SrcBlock);
        end

        if isempty(pc(p).DstBlock)
            rows(end + 1, :) = {block, pc(p).Type, src, ''}; %#ok<AGROW>
        else
            for d = 1:numel(pc(p).DstBlock)
                rows(end + 1, :) = {block, pc(p).Type, src, handle_name(pc(p).DstBlock(d))}; %#ok<AGROW>
            end
        end
    end
end

if isempty(rows)
    rows = cell(0, 4);
end

port_table = cell2table(rows, 'VariableNames', ...
    {'Block', 'PortType', 'SourceBlock', 'DestinationBlock'});
end

function value = get_safe(handle_or_path, param_name)
try
    value = get_param(handle_or_path, param_name);
    if isnumeric(value)
        value = mat2str(value);
    elseif isstring(value)
        value = char(value);
    elseif isempty(value)
        value = '';
    end
catch
    value = '';
end
end

function name = handle_name(handle_value)
if isempty(handle_value) || handle_value == -1
    name = '';
    return;
end

try
    name = getfullname(handle_value);
catch
    name = '';
end
end

function name = port_name(port_handle)
if isempty(port_handle) || port_handle == -1
    name = '';
    return;
end

try
    port_type = get_param(port_handle, 'PortType');
catch
    port_type = '';
end

try
    port_number = get_param(port_handle, 'PortNumber');
catch
    port_number = [];
end

if isempty(port_number)
    name = char(string(port_type));
else
    name = sprintf('%s%d', char(string(port_type)), port_number);
end
end

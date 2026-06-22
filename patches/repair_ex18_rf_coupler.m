function repair_ex18_rf_coupler(model)
%REPAIR_EX18_RF_COUPLER 重新生成包含完整 RF 耦合器链路的 ex18 模型。
%
%   当前 ex18 的 RF 前端已经由 build_ex18_sfw_top.m 统一生成。为了避免
%   对已有 RF 物理网络做局部补线时产生孤立网络，本函数只作为兼容入口，
%   直接调用重建脚本恢复干净模型。

if nargin < 1 || isempty(model)
    model = 'ex18_sfw_top';
end

if ~strcmp(model, 'ex18_sfw_top')
    warning('repair_ex18_rf_coupler:ModelIgnored', ...
        '当前修复入口只重建 ex18_sfw_top，传入的模型名已忽略。');
end

build_ex18_sfw_top();
fprintf('已通过 build_ex18_sfw_top 重新生成完整 RF 耦合器链路。\n');
end

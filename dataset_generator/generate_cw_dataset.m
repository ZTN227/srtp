function manifest = generate_cw_dataset()  %负责参数集合的管理


root = fileparts(fileparts(mfilename('fullpath')));  %得到当前`generate_cw_dataset.m`完整路径

datasetName = 'cw_two_sample_demo';
dataRoot = fullfile(root, 'output', 'datasets', datasetName);
manifest = fullfile(dataRoot, 'manifest.jsonl');
if ~exist(dataRoot, 'dir'), mkdir(dataRoot); end  %如果数据集输出总文件夹不存在，则创建
numSamples = 3;              % 样本总数

fid = fopen(manifest, 'w');  %每次运行清空旧 manifest 文件
assert(fid ~= -1, 'Cannot write %s.', manifest);
fclose(fid);

rng(20260919, 'twister');  %固定随机种子
samples = make_cw_parameter_set(numSamples);
for k = 1:numel(samples)
    meta = generate_bellhop_sample(samples(k), dataRoot, datasetName);
    appendLine(manifest, jsonencode(meta));
    fprintf('[%d/%d] %s\n', k, numel(samples), meta.audio_path);
end

fprintf('Dataset manifest created:\n%s\n', manifest);
end

function appendLine(path, text)
fid = fopen(path, 'a');
assert(fid ~= -1, 'Cannot append to %s.', path);
closer = onCleanup(@() fclose(fid));
fprintf(fid, '%s\n', text);
end

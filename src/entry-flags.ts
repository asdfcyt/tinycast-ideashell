/**
 * 待办列表不再是单独的命令（避免搜索栏多一个入口）：
 * Todos / 菜单栏用 launchCommand 打开 Notes，并带上这个暗号参数，Notes 命令看到后渲染待办列表。
 */
export const TODOS_LIST_QUERY = "__todos_list__";

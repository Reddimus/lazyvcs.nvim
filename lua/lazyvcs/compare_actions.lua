-- One catalog for the sidebar, commands, pane mappings, and help.
return {
	{ name = "review", key = "<CR>", description = "Review selected file" },
	{ name = "preview", key = "P", description = "Preview without leaving the list" },
	{ name = "edit", key = "o", description = "Edit comparison file", public = true },
	{ name = "files", description = "Focus comparison files", public = true },
	{ name = "width", key = "e", description = "Fit or restore comparison width", public = true },
	{ name = "metadata", key = "p", description = "Toggle metadata or properties", public = true },
	{ name = "base", key = "b", description = "Choose comparison base", public = true },
	{ name = "refresh", key = "R", description = "Refresh comparison", public = true },
	{ name = "help", key = "?", description = "Comparison help", public = true },
	{ name = "close", key = "q", description = "Close comparison", public = true },
}

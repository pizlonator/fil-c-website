#!/usr/bin/env bash

# Clean and prepare website directory
echo "Building Fil-C website..."

# First, process the header
HEADER_HTML=""
if [ -f "extra/header.md" ]; then
    echo "Processing header..."
    HEADER_HTML=$(Markdown.pl "extra/header.md")
fi

# Process the sidebar
SIDEBAR_HTML=""
if [ -f "extra/sidebar.md" ]; then
    echo "Processing sidebar..."
    SIDEBAR_HTML=$(Markdown.pl "extra/sidebar.md")
fi

# Process all markdown files in source directory
find source -name "*.md" -type f | while read -r md_file; do
    # Calculate output path
    rel_path="${md_file#source/}"
    html_path="website/${rel_path%.md}.html"
    html_dir="$(dirname "$html_path")"

    # Create output directory if it doesn't exist
    mkdir -p "$html_dir"

    # Convert markdown to HTML
    echo "Processing: $md_file -> $html_path"

    # Generate HTML with CSS reference
    cat <<EOF > "$html_path"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Fil-C</title>
    <link rel="stylesheet" href="/fil.css">
</head>
<body>
    <header class="header">
$HEADER_HTML
    </header>
    <div class="container">
        <aside class="sidebar">
$SIDEBAR_HTML
        </aside>
        <main class="content">
EOF

    # Process markdown and add to HTML
    Markdown.pl "$md_file" >> "$html_path"

    # Close HTML tags
    cat <<EOF >> "$html_path"
        </main>
    </div>
</body>
</html>
EOF
done

echo "Build complete!"
#!/bin/bash

# Clean and prepare website directory
echo "Building Fil-C website..."

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
EOF
    
    # Process markdown and add to HTML
    Markdown.pl "$md_file" >> "$html_path"
    
    # Close HTML tags
    cat <<EOF >> "$html_path"
</body>
</html>
EOF
done

echo "Build complete!"
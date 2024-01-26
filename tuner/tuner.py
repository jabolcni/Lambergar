import argparse

def modify_lines(file_path):
    with open(file_path, 'r') as file:
        lines = file.readlines()

    with open(file_path, 'w') as file:
        for line in lines:
            if "// TUNER ON" in line and line.lstrip().startswith("//"):
                index = line.index("//")
                # Uncomment the line
                file.write(line[:index] + line[index+2:])
            elif "// TUNER OFF" in line and not line.lstrip().startswith("//"):
                # Comment the line
                file.write("//" + line)
            else:
                # Write the line as it is
                file.write(line)

def uncomment_tnr_lines(file_path):
    with open(file_path, 'r') as file:
        lines = file.readlines()

    with open(file_path, 'w') as file:
        for line in lines:
            if line.lstrip().startswith("//tnr."):
                # Find the index where "//tnr." starts
                index = line.index("//tnr.")
                # Write the line without "//" but with original leading whitespaces
                file.write(line[:index] + line[index+2:])

            else:
                # Write the line as it is
                file.write(line)

def modify_lines_reverse(file_path):
    with open(file_path, 'r') as file:
        lines = file.readlines()

    with open(file_path, 'w') as file:
        for line in lines:
            if "// TUNER ON" in line and not line.lstrip().startswith("//"):
                # Comment the line
                file.write("//" + line)
            elif "// TUNER OFF" in line and line.lstrip().startswith("//"):
                # Uncomment the line
                file.write(line[2:])
            else:
                # Write the line as it is
                file.write(line)

def comment_tnr_lines(file_path):
    with open(file_path, 'r') as file:
        lines = file.readlines()

    with open(file_path, 'w') as file:
        for line in lines:
            if line.lstrip().startswith("tnr."):
                index = line.index("tnr.")
                # Comment the line
                file.write(line[:index] + "//" + line[index:])
                #file.write("//" + line)
            else:
                # Write the line as it is
                file.write(line)

def main():
    parser = argparse.ArgumentParser(description='Modify zig files.')
    parser.add_argument('--mode', type=str, help='Mode to switch to: "on" or "off"')
    args = parser.parse_args()

    if args.mode == "on":
        modify_lines("..\\src\\main.zig")
        modify_lines("..\\src\\evaluation.zig")
        uncomment_tnr_lines("..\\src\\evaluation.zig")
    elif args.mode == "off":
        modify_lines_reverse("..\\src\\main.zig")
        modify_lines_reverse("..\\src\\evaluation.zig")
        comment_tnr_lines("..\\src\\evaluation.zig")

if __name__ == "__main__":
    main()


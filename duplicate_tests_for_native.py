#!/usr/bin/env python3

from shutil import copyfile
import os

last_original_test = 28
sql = './sql'
expected = './expected'
TO_MODIFY = ['create_ext', 'setup', 'deploy_update', 'new_set_behavior', '1_4_features', 'sub_retries', 'new_setup']
IF_NATIVE_START = """DO $$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
EXECUTE $sql$
"""
IF_NATIVE_END = """END IF;

END$$;
"""
MAKE_SET_DRIVER_FUNC = f"""CREATE FUNCTION set_driver() RETURNS VOID AS $BODY$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN
    ALTER TABLE pgl_ddl_deploy.set_configs ALTER COLUMN driver SET DEFAULT 'native'::pgl_ddl_deploy.driver;
END IF;

END;
$BODY$
LANGUAGE plpgsql;
"""
SET_DRIVER = 'SELECT set_driver();\n'

files = {}
for filename in os.listdir(sql):
    split_filename = filename.split("_", 1)
    number = int(split_filename[0])
    if number > last_original_test:
        next
    else:
        files[int(split_filename[0])] = split_filename[1]

def construct_filename(n, name):
    return f"{str(n).zfill(2)}_{name}"

def handle_rep_config(old, new, line_start, line_end, native_statements_to_add, output_offset_start=0, output_offset_end=0):
    n = 0
    if old.endswith('.out'):
        line_start = line_start + output_offset_start 
        line_end = line_end + output_offset_end
    with open(old) as oldfile, open(new, 'w') as newfile:
        for line in oldfile:
            n += 1
            if n == line_start:
                newfile.write(IF_NATIVE_START)
                newfile.write("\n".join(native_statements_to_add))
                newfile.write('$sql$;\nELSE\n')
                newfile.write(line)
            elif n == line_end:
                newfile.write(IF_NATIVE_END)
                newfile.write(line)
            else: 
                newfile.write(line)

def validate(name):
    if not name in TO_MODIFY:
        raise ValueError(f"name {name} is not in the list of modified files: {to_modify}")

def make_native_file(old, new):
    name = old.split("/")[2].split(".")[0].split("_", 1)[1]
    to_modify = ['create_ext', 'setup', 'deploy_update', 'new_set_behavior', '1_4_features', 'sub_retries', 'new_setup']
    if name == 'create_ext':
        validate(name) 
        removes = ['CREATE EXTENSION pglogical']
        with open(old) as oldfile, open(new, 'w') as newfile:
            for line in oldfile:
                if not any(remove in line for remove in removes):
                    newfile.write(line)
                else:
                    newfile.write("""DO $$
BEGIN

IF current_setting('server_version_num')::INT >= 100000 THEN\n""")
                    newfile.write("RAISE LOG '%', 'USING NATIVE';\n")
                    newfile.write('\nELSE\n')
                    newfile.write(line)
                    newfile.write(IF_NATIVE_END)
        with open(new, 'a') as newfile:
            newfile.write(MAKE_SET_DRIVER_FUNC)
            newfile.write(SET_DRIVER)
    elif name == 'setup':
        validate(name) 
        pubname_prefix = 'test'
        statements = []
        for i in range(1, 9):
            statements.append(f"CREATE PUBLICATION {pubname_prefix}{i};")
        handle_rep_config(old, new, 1, 23, statements, 0, -3) 
    elif name == 'deploy_update':
        validate(name) 
        pubname = 'testtemp'
        handle_rep_config(old, new, 24, 33, [f"CREATE PUBLICATION {pubname};"], 3, 2)
    elif name == 'new_set_behavior':
        validate(name) 
        handle_rep_config(old, new, 18, 37, ["CREATE PUBLICATION my_special_tables_1;", "CREATE PUBLICATION my_special_tables_2;"], -2, -4) 
    elif name == '1_4_features':
        validate(name) 
        handle_rep_config(old, new, 11, 29, ["CREATE PUBLICATION test_ddl_only;"], 11, 9) 
    elif name == 'sub_retries':
        validate(name) 
        with open(old) as oldfile, open(new, 'w') as newfile:
            for line in oldfile:
                if "CREATE EXTENSION" in line:
                    newfile.write(line)
                    newfile.write(SET_DRIVER)
                else:
                    newfile.write(line)
    elif name == 'new_setup':
        validate(name) 
        n = 0
        line_start = 22
        line_end = 40 
        output_offset_start = -6
        output_offset_end = -8
        if old.endswith('.out'):
            line_start = line_start + output_offset_start
            line_end = line_end + output_offset_end
        with open(old) as oldfile, open(new, 'w') as newfile:
            for line in oldfile:
                n += 1
                if "CREATE EXTENSION" in line:
                    newfile.write(line)
                    newfile.write(SET_DRIVER)
                elif n == line_start:
                    newfile.write(IF_NATIVE_START)
                    newfile.write(f"CREATE PUBLICATION testspecial;\n")
                    newfile.write('$sql$;\nELSE\n')
                    newfile.write(line)
                elif n == line_end: 
                    newfile.write(IF_NATIVE_END)
                    newfile.write(line)
                else:
                    newfile.write(line)
    else:
        copyfile(old, new)

new_test_names = []
for n, name in files.items():
    orig = construct_filename(n, name)
    new = construct_filename(n + last_original_test, name)
    make_native_file(f"{sql}/{orig}", f"{sql}/{new}")
    make_native_file(f"{expected}/{orig.replace('.sql','.out')}", f"{expected}/{new.replace('.sql','.out')}")
    new_test_names.append(new.replace('.sql', ''))

final = [f"\n           {test_name} \\" for test_name in new_test_names]
print("FILES MODIFIED:")
print("\n".join(TO_MODIFY))
print("".join(sorted(final)))

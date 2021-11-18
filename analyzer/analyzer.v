module analyzer

pub struct SemanticAnalyzer {
pub mut:
	cur_file_path string
	cursor        TreeCursor
	src_text      []byte
	store         &Store = &Store(0)
	cur_fn_name   string
	in_expr       bool
	// skips the local scopes and registers only
	// the top-level ones regardless of its
	// visibility
	is_import bool
}

const empty_custom_params = map[int]string{}
const empty_symbols = []&Symbol{}

fn (mut an SemanticAnalyzer) report(code int, range C.TSRange, symbols []&Symbol) {
	an.custom_report(code, range, symbols, analyzer.empty_custom_params)
}

fn (mut an SemanticAnalyzer) custom_report(code int, range C.TSRange, symbols []&Symbol, custom_params map[int]string) {
	mut err := AnalyzerError{
		code: code
		range: range
		file_path: an.store.cur_file_path
		parameters: []string{cap: symbols.len + custom_params.len}
	}

	for sym in symbols {
		mod_dir := os.dir(sym.file_path)
		mod_with_prefix := an.store.get_module_name_with_prefix(mod_dir)
		err.parameters << sym.gen_str_with_prefix(mod_with_prefix).replace('_literal', ' literal')
		unsafe { mod_dir.free() }
	}

	for i, str in custom_params {
		if i > err.parameters.len {
			err.parameters << str
		} else {
			err.parameters.insert(i, str)
		}
	}

	an.store.report_error(err)
}

const multiplicative_operators = ["*", "/", "%", "<<", ">>", "&", "&^"]
const additive_operators = ["+", "-", "|", "^"]
const comparative_operators = ["==", "!=", "<", "<=", ">", ">="]
const and_operators = ["&&"]
const or_operators = ["||"]

fn (mut an SemanticAnalyzer) binary_expr(node C.TSNode) &Symbol {
	op_node := node.child_by_field_name('operator')
	op := op_node.get_type()
	is_multiplicative := op in multiplicative_operators
	is_additive := op in additive_operators
	is_comparative := op in comparative_operators
	// is_and := op in and_operators
	// is_or := op in or_operators

	left_node := node.child_by_field_name('left')
	right_node := node.child_by_field_name('right')

	left_sym := an.convert_to_lit_type(left_node) or { an.expression(left_node) }
	right_sym := an.convert_to_lit_type(right_node) or { an.expression(right_node) }
	
	if op == '<<' {
		if an.in_expr {
			an.report(analyzer.array_append_expr_error, op_node.range(), analyzer.empty_symbols)
		} else if left_sym.kind == .array_ && left_sym.children[0] != right_sym {
			an.report(
				analyzer.append_type_mismatch_error,
				right_node.range(),
				[right_sym, left_sym]
			)
		} else {
			an.custom_report(
				analyzer.undefined_operation_error,
				node.range(),
				[left_sym, right_sym],
				{1: op}
			)
		}
	} else if is_multiplicative || is_additive {
		// check if left and right are both numeric types
		if left_sym.name !in analyzer.numeric_types_with_any_type || right_sym.name !in analyzer.numeric_types_with_any_type {
			if left_sym.name in analyzer.numeric_types_with_any_type || right_sym.name in analyzer.numeric_types_with_any_type {
				an.report(analyzer.mismatched_type_error, node.range(), [left_sym, right_sym])
			} else {
				an.custom_report(
					analyzer.undefined_operation_error,
					node.range(),
					[left_sym, right_sym],
					{1: op}
				)
			}

			return analyzer.void_type
		}
	} else if is_comparative {
		if left_sym != right_sym {
			an.report(analyzer.mismatched_type_error, node.range(), [left_sym, right_sym])
			return analyzer.void_type
		}
	} else {
		// check if left and right are both numeric types
		if left_sym.name != 'bool' || right_sym.name != 'bool' {
			an.report(analyzer.mismatched_type_error, node.range(), [left_sym, right_sym])
			return analyzer.void_type
		}
	}
	return left_sym
}

fn (an &Analyzer) convert_to_lit_type(node C.TSNode) ?&Symbol {
	node_type := node.get_type()
	if node_type == 'float_literal' || (node_type == 'int_literal' && node.get_text(an.src_text).int() < 17) {
		return an.store.find_symbol('', node_type)
	}	
	return none
}

fn (mut an SemanticAnalyzer) call_expr(node C.TSNode) &Symbol {
	fn_node := node.child_by_field_name('function')
	fn_sym := an.expression(fn_node)
	arguments_node := node.child_by_field_name('arguments')

	// check arguments
	for i, _ in fn_sym.children {
		arg_node := arguments_node.named_child(u32(i))
		// mut returned_sym := an.expression(arg_node)
		// if returned_sym.is_returnable() {
		// 	returned_sym = arg_sym.return_type
		// }

		// if returned_sym != arg_sym.return_type {
		// 	an.custom_report(
		// 		analyzer.invalid_argument_error, 
		// 		arg_node, 
		// 		[returned_sym, arg_sym.return_type],
		// 		{2: i.str(), 3: fn_sym.name}
		// 	)
		// }
		_ = an.expression(arg_node)
	}

	// TODO: or block checking

	if fn_sym.is_returnable() {
		return fn_sym.return_type
	} else {
		return fn_sym
	}
}

fn (mut an SemanticAnalyzer) array(node C.TSNode) &Symbol {
	items_len := node.named_child_count()
	if items_len == 0 {
		an.report(
			analyzer.untyped_empty_array_error,
			node.range(),
			analyzer.empty_symbols
		)
		return analyzer.void_type
	}

	first_item_node := node.named_child(0)
	mut expected_sym := an.expression(first_item_node)

	if expected_sym.is_void() {
		return analyzer.void_type
	} else if items_len > 1 {
		for i in u32(1) .. items_len {
			item_child_node := node.named_child(i)
			returned_item_sym := an.expression(item_child_node)
			if returned_item_sym != expected_sym {
				an.report(
					analyzer.invalid_array_element_type_error, 
					item_child_node.range(), 
					[expected_sym, returned_item_sym]
				)
				continue
			}
		}
	}

	symbol_name := '[]' + expected_sym.gen_str()
	return an.store.find_symbol('', symbol_name) or { 
		mut new_sym := Symbol{
			name: symbol_name.clone()
			is_top_level: true
			file_path: os.join_path(an.store.cur_dir, 'placeholder.vv')
			file_version: 0
			kind: .array_
		}
		new_sym.add_child(mut expected_sym, false) or {}
		an.store.register_symbol(mut new_sym) or { analyzer.void_type } 
	}
}

fn (mut an SemanticAnalyzer) selector_expr(node C.TSNode) &Symbol {
	operand := node.child_by_field_name('operand')
	mut root_sym := an.expression(operand)
	if root_sym.is_void() {
		root_sym = an.store.infer_symbol_from_node(operand, an.src_text) or {
			analyzer.void_type
		}
	}
	
	if !root_sym.is_void() {
		if root_sym.is_returnable() {
			root_sym = root_sym.return_type
		}

		field_node := node.child_by_field_name('field')
		child_name := field_node.get_text(an.src_text)
		got_child_sym := root_sym.children.get(child_name) or {
			mut base_root_sym := root_sym
			if root_sym.kind == .ref || root_sym.kind == .chan_ || root_sym.kind == .optional {
				base_root_sym = root_sym.parent
			} else if root_sym.kind == .array_ {
				base_root_sym = an.store.find_symbol('', 'array') or { analyzer.void_type }
			} else if root_sym.kind == .map_ {
				base_root_sym = an.store.find_symbol('', 'map') or { analyzer.void_type }
			}
			base_root_sym.children.get(child_name) or {
				analyzer.void_type 
			}
		}

		// NOTE: transfer this to `store.infer_symbol_from_node` if possible
		mut got_sym_kind_from_embed := SymbolKind.void
		mut method_or_field_sym := analyzer.void_type
		mut method_or_field_typ_idx := -1

		for child_sym_idx, child_sym in root_sym.children {
			if child_sym.kind == .embedded_field {
				returned_sym := child_sym.return_type.children.get(child_name) or {
					continue
				}

				if method_or_field_typ_idx == -1 {
					method_or_field_sym = returned_sym
					method_or_field_typ_idx = child_sym_idx
					got_sym_kind_from_embed = returned_sym.kind
				} else {
					err_code := if got_sym_kind_from_embed == .function {
						analyzer.ambiguous_method_error
					} else {
						analyzer.ambiguous_field_error
					}

					mut range := field_node.range()
					if node.parent().get_type() == 'call_expression' {
						range = range.extend(node.next_named_sibling().range())
					}

					an.custom_report(err_code, range, analyzer.empty_symbols, {0: child_name})
				}
			}
		}	

		return if method_or_field_sym.is_void() {
			got_child_sym
		} else {
			method_or_field_sym
		}
	}
	return root_sym
}

fn (mut an SemanticAnalyzer) type_init(node C.TSNode) &Symbol {
	type_node := node.child_by_field_name('type')
	// body_node := node.child_by_field_name('body')

	sym_kind, module_name, symbol_name := symbol_name_from_node(type_node, an.src_text)
	defer {
		unsafe {
			module_name.free()
			symbol_name.free()
		}
	}

	match sym_kind {
		.array_, .variadic {
			el_node := type_node.child_by_field_name('element')
			el_sym := an.store.find_symbol_by_type_node(el_node, an.src_text) or {
				analyzer.void_type
			}

			if el_sym.is_void() || el_sym.kind == .placeholder {
				an.custom_report(
					analyzer.unknown_type_error,
					el_node.range(),
					analyzer.empty_symbols,
					{0: el_node.get_text(an.src_text)}
				)
			}

			if el_sym.kind == .sumtype {
				mut range := type_node.range()
				if type_node.get_type() == 'fixed_array_type' {
					range = node.range()
				} else {
					range = range.extend(type_node.next_sibling().child(0).range())
				}
				
				an.report(analyzer.invalid_sumtype_array_init_error, range, analyzer.empty_symbols)
			}

			// if type_node.get_type() == 'fixed_array_type' {
			// 	// limit := type_node.child_by_field_name('limit')


			// }
		}
		.map_ {
			// key_node := type_node.child_by_field_name('key')
			// key_sym := an.store.find_symbol_by_type_node(key_node, an.src_text) or {
			// 	analyzer.void_type
			// }
			
			// if key_sym.is_void() || key_sym.kind == .placeholder {
			// 	an.custom_report(
			// 		analyzer.unknown_type_error,
			// 		key_node.range(),
			// 		analyzer.empty_symbols,
			// 		{0: key_node.get_text(an.src_text)}
			// 	)
			// }
			
			// val_node := node.child_by_field_name('value')
			// val_sym := an.store.find_symbol_by_type_node(val_node, an.src_text) or {
			// 	analyzer.void_type
			// }

			// if val_sym.is_void() || val_sym.kind == .placeholder {
			// 	an.custom_report(
			// 		analyzer.unknown_type_error,
			// 		val_node.range(),
			// 		analyzer.empty_symbols,
			// 		{0: val_node.get_text(an.src_text)}
			// 	)
			// }
		}
		.chan_, .ref, .optional {
			// el_node := type_node.named_child(0)
			// el_sym := an.store.find_symbol_by_type_node(el_node, an.src_text) or {
			// 	analyzer.void_type
			// }

			// if el_sym.is_void() || el_sym.kind == .placeholder {
			// 	an.custom_report(
			// 		analyzer.unknown_type_error,
			// 		el_node.range(),
			// 		analyzer.empty_symbols,
			// 		{0: el_node.get_text(an.src_text)}
			// 	)
			// }
		}
		else {}
	}

	return an.store.find_symbol(module_name, symbol_name) or {
		analyzer.void_type
	}
}

fn (mut an SemanticAnalyzer) unary_expr(node C.TSNode) &Symbol {
	// op_node := node.child_by_field_name('operator')
	operand_node := node.child_by_field_name('operand')
	operand_sym := an.expression(operand_node)

	// if an.in_expr {
		

	// 	match op_node.get_type() {
	// 		'<-' {
				
	// 		}
	// 		else { return analyzer.void_type }
	// 	}
	// }

	return operand_sym
}

fn (mut an SemanticAnalyzer) expression(node C.TSNode) &Symbol {
	node_typ := node.get_type()
	match node_typ {
		'type_initializer' {
			return an.type_init(node)
		}
		'parenthesized_expression' {
			return an.expression(node.named_child(0))
		}
		'array' {
			return an.array(node)
		}
		'call_expression' {
			return an.call_expr(node)
		}
		'unary_expression' {
			return an.unary_expr(node)
		}
		'binary_expression' {
			return an.binary_expr(node)
		}
		'selector_expression' {
			return an.selector_expr(node)
		}
		'int_literal', 'float_literal' {
			return an.store.infer_value_type_from_node(node, an.src_text)
		}
		else {
			sym := an.store.infer_symbol_from_node(node, an.src_text) or {
				analyzer.void_type
			}

			if sym.kind == .variable || sym.kind == .field {
				if sym.name == an.cur_fn_name && sym.kind == .variable {
					if node.parent().get_type() == 'call_expression' {
						an.custom_report(
							analyzer.ambiguous_call_error,
							node.parent().range(),
							analyzer.empty_symbols,
							{0: an.cur_fn_name, 1: an.cur_fn_name, 2: an.cur_fn_name}
						)
					}
					return analyzer.void_type
				}

				return sym.return_type
			} else {
				return sym
			}
		}
	}
	return analyzer.void_type
}

fn (mut an SemanticAnalyzer) import_decl(node C.TSNode) ? {
	// Most of the checking is already done in `import_modules_from_trees`
	// Check only the symbols if they are available
	symbols := node.child_by_field_name('symbols') ?
	module_name_node := node.child_by_field_name('path') ?
	module_name := module_name_node.code(an.src_text)
	// defer { unsafe { module_name.free() } }

	module_path := an.store.get_module_path_opt(module_name) or {
		// `import_modules_from_trees` already reported it
		return
	}

	list := symbols.named_child(0) ?
	symbols_count := list.named_child_count()
	for i := u32(0); i < symbols_count; i++ {
		sym := list.named_child(i) ?
		if sym.is_null() {
			continue
		}

		symbol_name := sym.code(an.src_text)
		got_sym := an.store.symbols[module_path].get(symbol_name) or {
			an.custom_report(analyzer.not_found_error, sym_ident_node.range(), [], {0: symbol_name})
			continue
		}
		if int(got_sym.access) < int(SymbolAccess.public) {
			an.custom_report(analyzer.not_found_error, sym_ident_node.range(), [], {0: symbol_name})
		}
	}
}

fn (mut an SemanticAnalyzer) assignment_stmt(node C.TSNode) {
	op_node := node.child_by_field_name('operator')
	op := op_node.get_type()[..1]
	is_multiplicative := op in multiplicative_operators
	is_additive := op in additive_operators

	left_node := node.child_by_field_name('left')
	right_node := node.child_by_field_name('right')
	left_sym_count := left_node.named_child_count()
	right_sym_count := right_node.named_child_count()

	if left_sym_count == right_sym_count {
		an.in_expr = true
		for i in u32(0) .. u32(left_sym_count) {
			left_child := left_node.named_child(i)
			left_sym := an.expression(left_child)
			right_child := right_node.named_child(i)
			mut right_sym := an.expression(right_child)
			
			if is_multiplicative || is_additive {
				// has_overloaded_method := left_sym.children.has(op_node.get_type())
				if left_sym.name in analyzer.numeric_types_with_any_type || right_sym.name in analyzer.numeric_types_with_any_type {
					an.report(analyzer.mismatched_type_error, node.range(), [left_sym, right_sym])
				} else {
					an.custom_report(
						analyzer.undefined_operation_error,
						op_node.range(),
						[left_sym, right_sym],
						{1: op}
					)
				}
			} else if right_child.get_type() == 'unary_expression' && left_sym != right_sym {
				unary_op_node := right_child.child_by_field_name('operator') or { continue }
				if right_sym.kind == .chan_ {
					right_sym = right_sym.parent_sym
				}
				
				an.custom_report(
					analyzer.invalid_assignment_error,
					unary_op_node.range(),
					[left_sym, right_sym],
					{0: left_child.get_text(an.src_text)}
				)
			} else {
				// TODO:
			}
		}
		an.in_expr = false
	}
}

fn (mut an SemanticAnalyzer) short_var_decl(node C.TSNode) {
	right := node.child_by_field_name('right')
	right_count := right.named_child_count()
	an.in_expr = true
	for i in u32(0) .. right_count {
		right_child := right.named_child(i)
		if right_child.get_type() == 'unary_expression' && right_child.child_by_field_name('operator').get_type() == '<-' {
			an.report(
				analyzer.send_operator_in_var_decl_error,
				right_child.child_by_field_name('operator').range(),
				analyzer.empty_symbols
			)
		} else {
			_ = an.expression(right_child)
		}
	}
	an.in_expr = false
}

fn (mut an SemanticAnalyzer) send_statement(node C.TSNode) {
	chan_node := node.child_by_field_name('channel')
	val_node := node.child_by_field_name('value')
	chan_typ_sym := an.expression(chan_node)
	val_typ_sym := an.expression(val_node)
	if chan_typ_sym.kind != .chan_ {
		an.report(
			analyzer.send_channel_invalid_chan_type_error,
			chan_node.range(),
			[chan_typ_sym]
		)
	} else if val_typ_sym != chan_typ_sym.parent {
		an.report(
			analyzer.send_channel_invalid_value_type_error,
			val_node.range(),
			[val_typ_sym, chan_typ_sym]
		)
	}
}

fn (mut an SemanticAnalyzer) assert_statement(node C.TSNode) {
	expr_node := node.named_child(0)
	expr_typ_sym := an.expression(expr_node)
	if expr_typ_sym.name != 'bool' {
		an.report(
			analyzer.invalid_assert_type_error,
			expr_node.range(),
			[expr_typ_sym]
		)
	}
}

fn (mut an SemanticAnalyzer) block(node C.TSNode) {
	body_sym_len := node.named_child_count()
	for i := u32(0); i < body_sym_len; i++ {
		stmt_node := node.named_child(i)
		stmt_type := stmt_node.get_type()
		// eprintln('$i : $stmt_type ${stmt_node.get_text(an.src_text)} ${stmt_node.start_byte()}')
		match stmt_type {
			'short_var_declaration' {
				an.short_var_decl(stmt_node)
			}
			// 'for_statement' {
			// 	sr.for_statement(stmt_node) or { continue }
			// }
			// 'if_expression' {
			// 	an.if_expression(stmt_node) or { continue }
			// }
			'assignment_statement' {
				an.assignment_stmt(stmt_node)
			}
			'block' {
				an.block(stmt_node)
			}
			'send_statement' {
				an.send_statement(stmt_node)
			}
			'assert_statement' {
				an.assert_statement(stmt_node)
			}
			else {
				_ = an.expression(stmt_node)
			}
		}
	}
}

fn (mut an SemanticAnalyzer) const_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) struct_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) interface_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) enum_decl(node C.TSNode) {
}

fn (mut an SemanticAnalyzer) fn_decl(node C.TSNode) {
	name_node := node.child_by_field_name('name')
	an.cur_fn_name = name_node.get_text(an.src_text)
	body_node := node.child_by_field_name('body')
	an.block(body_node)
	an.cur_fn_name = ''
}

fn (mut an SemanticAnalyzer) type_decl(node C.TSNode) {
	types_node :=  node.child_by_field_name('types')
	types_count := types_node.named_child_count()

	for i in u32(0) .. types_count {
		type_node := types_node.named_child(i)
		got_sym := an.store.find_symbol_by_type_node(type_node, an.src_text) or {
			continue
		}

		if got_sym.is_void() || got_sym.kind == .placeholder {
			an.custom_report(
				analyzer.unknown_type_error, 
				type_node.range(), 
				analyzer.empty_symbols,
				{0: type_node.get_text(an.src_text)}
			)
		}
	}
}

pub fn (mut an SemanticAnalyzer) top_level_statement() {
	current_node := an.cursor.current_node() or { return }

	match current_node.type_name() {
		'import_declaration' {
			an.import_decl(current_node) or {}
		}
		'const_declaration' {
			an.const_decl(current_node)
		}
		'struct_declaration' {
			an.struct_decl(current_node)
		}
		'interface_declaration' {
			an.interface_decl(current_node)
		}
		'enum_declaration' {
			an.enum_decl(current_node)
		}
		'function_declaration' {
			an.fn_decl(current_node)
		}
		'type_declaration' {
			an.type_decl(current_node)
		}
		else {}
	}
}

// analyze analyzes the given tree
pub fn (mut store Store) analyze(tree &C.TSTree, src_text []byte) {
	mut an := SemanticAnalyzer{
		store: unsafe { store }
		src_text: src_text
		cursor: new_tree_cursor(tree.root_node())
	}

	an.cursor.to_first_child()
	for _ in an.cursor {
		an.top_level_statement()
	}

	// unsafe { an.cursor.free() }
}

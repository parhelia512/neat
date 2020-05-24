module array;

import backend.backend;
import base;
import boilerplate;
import parser;
import std.algorithm;
import std.format : format;
import std.range;
import struct_;
import types;

class ASTArray : ASTType
{
    ASTType elementType;

    override Type compile(Namespace namespace)
    {
        return new Array(this.elementType.compile(namespace));
    }

    override string toString() const
    {
        return format!"%s[]"(this.elementType);
    }

    mixin(GenerateThis);
}

// ptr, length
class Array : Type
{
    Type elementType;

    // TODO remove; grab size from backend type!
    override size_t size() const
    {
        return 16;
    }

    override BackendType emit(BackendModule mod)
    {
        return mod.structType([
            mod.pointerType(this.elementType.emit(mod)),
            mod.intType]); // TODO mod.wordType / mod.wordSize
    }

    override string toString() const
    {
        return format!"%s[]"(this.elementType);
    }

    override bool opEquals(const Object other) const
    {
        auto otherArray = cast(Array) other;

        return otherArray && otherArray.elementType == elementType;
    }

    mixin(GenerateThis);
}

class ArrayLength : Expression
{
    Expression arrayValue;

    override Type type()
    {
        // TODO word type
        return new Integer;
    }

    override Reg emit(Generator output)
    {
        auto arrayReg = this.arrayValue.emit(output);
        return output.fun.field(arrayValue.type.emit(output.mod), arrayReg, 1);
    }

    mixin(GenerateThis);
}

Reg getArrayPointer(Generator output, Type arrayType, Reg arrayReg)
{
    return output.fun.field(arrayType.emit(output.mod), arrayReg, 0);
}

class ArrayPointer : Expression
{
    Type elementType;

    Expression arrayValue;

    override Type type()
    {
        return new Pointer(this.elementType);
    }

    override Reg emit(Generator output)
    {
        auto arrayReg = this.arrayValue.emit(output);
        return getArrayPointer(output, this.arrayValue.type, arrayReg);
    }

    mixin(GenerateThis);
}

class ASTArrayLiteral : ASTSymbol
{
    struct Entry
    {
        ASTSymbol symbol;

        bool spread;
    }

    Entry[] elements;

    override ArrayLiteral compile(Namespace namespace)
    {
        ArrayLiteral.Element[] elements;
        Type elementType;
        foreach (entry; this.elements)
        {
            auto newExpression = entry.symbol.compile(namespace).beExpression;
            Type expressionElementType;
            if (entry.spread)
            {
                auto subtype = cast(Array) newExpression.type;
                assert(subtype, "spread entry must be array");
                expressionElementType = subtype.elementType;
            }
            else
            {
                expressionElementType = newExpression.type;
            }
            if (!elementType) elementType = expressionElementType;
            else assert(expressionElementType == elementType);
            elements ~= ArrayLiteral.Element(newExpression, entry.spread);
        }
        if (!elementType) assert(false, "cannot type empty literal");
        return new ArrayLiteral(elementType, elements);
    }

    override string toString() const
    {
        return format!"[%(%s, %)]"(this.elements);
    }

    mixin(GenerateThis);
}

class ArrayLiteral : Expression
{
    struct Element
    {
        Expression expression;

        bool spread;
    }
    Type elementType;

    Element[] elements;

    override Type type()
    {
        return new Array(elementType);
    }

    override Reg emit(Generator output)
    {
        auto voidp = output.mod.pointerType(output.mod.voidType);
        auto intType = output.mod.intType;

        Reg lenPtr = output.fun.alloca(intType); // TODO word type
        const numNonSpreadElements = this.elements.filter!(a => !a.spread).count;
        output.fun.store(intType, lenPtr, output.fun.intLiteral(cast(int) numNonSpreadElements));

        // add the lengths of each array element
        foreach (i, element; this.elements)
        {
            if (element.spread)
            {
                Reg len = output.fun.load(intType, lenPtr);
                // TODO prevent double emit when we can have non-ref struct base
                Reg addLen = (new ArrayLength(element.expression)).emit(output);
                Reg sumLen = output.fun.call(intType, "cxruntime_int_add", [len, addLen]);
                output.fun.store(intType, lenPtr, sumLen);
            }
        }
        Reg memSize = output.fun.call(
            intType, "cxruntime_int_mul", [
                output.fun.load(intType, lenPtr),
                output.fun.intLiteral(cast(int) this.elementType.size)]);

        Reg ptr = output.fun.call(voidp, "malloc", [memSize]);
        Reg currentOffsetPtr = output.fun.alloca(intType);
        output.fun.store(intType, currentOffsetPtr, output.fun.intLiteral(0));

        foreach (i, element; this.elements)
        {
            Reg currentOffset = output.fun.load(intType, currentOffsetPtr);
            Reg ptrOffsetReg = output.fun.call(voidp, "ptr_offset", [ptr, currentOffset]);

            if (element.spread)
            {
                // TODO prevent double emit when we can have non-ref struct base
                Reg elementLen = (new ArrayLength(element.expression)).emit(output);
                Reg elementPtr = (new ArrayPointer(this.elementType, element.expression)).emit(output);
                Reg elementSize = output.fun.call(
                    intType, "cxruntime_int_mul", [elementLen, output.fun.intLiteral(cast(int) this.elementType.size)]);

                output.fun.call(voidp, "memcpy", [ptrOffsetReg, elementPtr, elementSize]);
                output.fun.store(intType, currentOffsetPtr, output.fun.call(
                    intType, "cxruntime_int_add", [currentOffset, elementSize]));
            }
            else
            {
                output.fun.store(elementType.emit(output.mod), ptrOffsetReg, element.expression.emit(output));
                output.fun.store(intType, currentOffsetPtr, output.fun.call(
                    intType, "cxruntime_int_add", [
                        currentOffset,
                        output.fun.intLiteral(cast(int) this.elementType.size)]));
            }
        }
        auto structType = type.emit(output.mod);
        // TODO allocaless
        Reg structReg = output.fun.alloca(structType);
        Reg ptrField = output.fun.fieldOffset(structType, structReg, 0);
        Reg lenField = output.fun.fieldOffset(structType, structReg, 1);

        output.fun.store(voidp, ptrField, ptr);
        output.fun.store(intType, lenField, output.fun.load(intType, lenPtr));
        return output.fun.load(structType, structReg);
    }

    mixin(GenerateThis);
}

class ASTArraySlice : ASTSymbol
{
    ASTSymbol array;

    ASTSymbol lower;

    ASTSymbol upper;

    override ArraySlice compile(Namespace namespace)
    {
        return new ArraySlice(
            this.array.compile(namespace).beExpression,
            this.lower.compile(namespace).beExpression,
            this.upper.compile(namespace).beExpression);
    }

    override string toString() const
    {
        return format!"%s[%s .. %s]"(array, lower, upper);
    }

    mixin(GenerateThis);
}

class ArraySlice : Expression
{
    Expression array;

    Expression lower;

    Expression upper;

    override Type type() { return this.array.type; }

    override Reg emit(Generator output)
    {
        auto voidp = output.mod.pointerType(output.mod.voidType);
        auto intType = output.mod.intType;

        auto arrayType = cast(Array) this.array.type;
        assert(arrayType, "slice of non-array");

        auto arrayReg = this.array.emit(output);
        auto lowerReg = this.lower.emit(output);
        auto upperReg = this.upper.emit(output);
        auto ptr = getArrayPointer(output, arrayType, arrayReg);
        // ptr = ptr + lower
        Reg lowerOffset = output.fun.call(
            intType, "cxruntime_int_mul", [
                lowerReg,
                output.fun.intLiteral(cast(int) arrayType.elementType.size)]);
        Reg newPtr = output.fun.call(voidp, "ptr_offset", [ptr, lowerOffset]);
        // len = upper - lower
        Reg newLen = output.fun.call(intType, "cxruntime_int_sub", [upperReg, lowerReg]);

        // TODO allocaless
        auto structType = arrayType.emit(output.mod);
        Reg structReg = output.fun.alloca(structType);
        Reg ptrField = output.fun.fieldOffset(structType, structReg, 0);
        Reg lenField = output.fun.fieldOffset(structType, structReg, 1);

        output.fun.store(voidp, ptrField, newPtr);
        output.fun.store(intType, lenField, newLen);
        return output.fun.load(structType, structReg);
    }

    mixin(GenerateThis);
}
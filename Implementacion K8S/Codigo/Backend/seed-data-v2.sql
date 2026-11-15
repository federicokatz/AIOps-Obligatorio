-- =============================================
-- Script de datos iniciales para PharmaGo
-- Ejecutar en SSMS o DBeaver (script completo)
-- Base de datos: PharmaDb
-- =============================================

USE PharmaDb;
GO

-- =============================================
-- 1. ROLES (obligatorios para la aplicación)
-- Administrator, Employee, Owner son usados en AuthorizationFilter
-- =============================================
IF NOT EXISTS (SELECT 1 FROM Roles WHERE Name = 'Administrator')
    INSERT INTO Roles (Name) VALUES ('Administrator');
IF NOT EXISTS (SELECT 1 FROM Roles WHERE Name = 'Employee')
    INSERT INTO Roles (Name) VALUES ('Employee');
IF NOT EXISTS (SELECT 1 FROM Roles WHERE Name = 'Owner')
    INSERT INTO Roles (Name) VALUES ('Owner');
GO

-- =============================================
-- 2. UNIT MEASURES (para medicamentos)
-- =============================================
IF NOT EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Gramos')
    INSERT INTO UnitMeasures (Name, Deleted) VALUES ('Gramos', 0);
IF NOT EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Mililitros')
    INSERT INTO UnitMeasures (Name, Deleted) VALUES ('Mililitros', 0);
IF NOT EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Unidades')
    INSERT INTO UnitMeasures (Name, Deleted) VALUES ('Unidades', 0);
GO

-- =============================================
-- 3. PRESENTATIONS (para medicamentos)
-- =============================================
IF NOT EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Tabletas')
    INSERT INTO Presentations (Name, Deleted) VALUES ('Tabletas', 0);
IF NOT EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Capsulas')
    INSERT INTO Presentations (Name, Deleted) VALUES ('Capsulas', 0);
IF NOT EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Jarabe')
    INSERT INTO Presentations (Name, Deleted) VALUES ('Jarabe', 0);
IF NOT EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Crema')
    INSERT INTO Presentations (Name, Deleted) VALUES ('Crema', 0);
GO

-- =============================================
-- 4. FARMACIA DE EJEMPLO
-- =============================================
IF NOT EXISTS (SELECT 1 FROM Pharmacys WHERE Name = 'Farmacia Central')
    INSERT INTO Pharmacys (Name, Address) VALUES ('Farmacia Central', 'Av. 18 de Julio 1234, Montevideo');
GO

-- =============================================
-- 5. USUARIOS DE PRUEBA (con roles)
-- Password para todos: Abcdef12. (cumple regex: mayúscula, minúscula, número, especial, 8+ chars)
-- Subconsultas en lugar de DECLARE: DBeaver ejecuta cada sentencia por separado
-- y las variables T-SQL no sobreviven entre lotes.
-- =============================================
IF NOT EXISTS (SELECT 1 FROM Users WHERE UserName = 'admin')
    INSERT INTO Users (UserName, Email, Password, Address, RegistrationDate, RoleId, PharmacyId)
    SELECT 'admin', 'admin@pharmago.com', 'Abcdef12.', 'Oficina Central', GETDATE(),
           (SELECT Id FROM Roles WHERE Name = 'Administrator'),
           NULL;

IF NOT EXISTS (SELECT 1 FROM Users WHERE UserName = 'owner001')
    INSERT INTO Users (UserName, Email, Password, Address, RegistrationDate, RoleId, PharmacyId)
    SELECT 'owner001', 'owner@farmaciacentral.com', 'Abcdef12.', 'Av. Italia 500', GETDATE(),
           (SELECT Id FROM Roles WHERE Name = 'Owner'),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central');

IF NOT EXISTS (SELECT 1 FROM Users WHERE UserName = 'empleado01')
    INSERT INTO Users (UserName, Email, Password, Address, RegistrationDate, RoleId, PharmacyId)
    SELECT 'empleado01', 'empleado@farmaciacentral.com', 'Abcdef12.', 'Av. Brasil 200', GETDATE(),
           (SELECT Id FROM Roles WHERE Name = 'Employee'),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central');
GO

-- =============================================
-- 6. INVITACIONES DE EJEMPLO (para registro de nuevos usuarios)
-- UserCode debe ser 6 dígitos
-- =============================================
IF EXISTS (SELECT 1 FROM Pharmacys WHERE Name = 'Farmacia Central') AND
   EXISTS (SELECT 1 FROM Roles WHERE Name = 'Employee') AND
   NOT EXISTS (SELECT 1 FROM Invitations WHERE UserName = 'nuevo_empleado' AND IsActive = 1)
    INSERT INTO Invitations (UserName, UserCode, IsActive, Created, PharmacyId, RoleId)
    SELECT 'nuevo_empleado', '123456', 1, GETDATE(),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central'),
           (SELECT Id FROM Roles WHERE Name = 'Employee');
GO

-- =============================================
-- 7. MEDICAMENTOS DE EJEMPLO
-- =============================================
IF NOT EXISTS (SELECT 1 FROM Drugs WHERE Code = 'PARA001')
   AND EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Gramos')
   AND EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Tabletas')
   AND EXISTS (SELECT 1 FROM Pharmacys WHERE Name = 'Farmacia Central')
    INSERT INTO Drugs (Code, Name, Symptom, Quantity, Price, Stock, Prescription, Deleted, UnitMeasureId, PresentationId, PharmacyId)
    SELECT 'PARA001', 'Paracetamol 500mg', 'Dolor y fiebre', 20, 150.00, 100, 0, 0,
           (SELECT Id FROM UnitMeasures WHERE Name = 'Gramos'),
           (SELECT Id FROM Presentations WHERE Name = 'Tabletas'),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central');

IF NOT EXISTS (SELECT 1 FROM Drugs WHERE Code = 'IBUP002')
   AND EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Gramos')
   AND EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Tabletas')
   AND EXISTS (SELECT 1 FROM Pharmacys WHERE Name = 'Farmacia Central')
    INSERT INTO Drugs (Code, Name, Symptom, Quantity, Price, Stock, Prescription, Deleted, UnitMeasureId, PresentationId, PharmacyId)
    SELECT 'IBUP002', 'Ibuprofeno 400mg', 'Dolor e inflamación', 30, 280.50, 80, 0, 0,
           (SELECT Id FROM UnitMeasures WHERE Name = 'Gramos'),
           (SELECT Id FROM Presentations WHERE Name = 'Tabletas'),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central');

IF NOT EXISTS (SELECT 1 FROM Drugs WHERE Code = 'AMOX003')
   AND EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Mililitros')
   AND EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Jarabe')
   AND EXISTS (SELECT 1 FROM Pharmacys WHERE Name = 'Farmacia Central')
    INSERT INTO Drugs (Code, Name, Symptom, Quantity, Price, Stock, Prescription, Deleted, UnitMeasureId, PresentationId, PharmacyId)
    SELECT 'AMOX003', 'Amoxicilina 250mg/5ml', 'Infecciones bacterianas', 60, 450.00, 50, 1, 0,
           (SELECT Id FROM UnitMeasures WHERE Name = 'Mililitros'),
           (SELECT Id FROM Presentations WHERE Name = 'Jarabe'),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central');

IF NOT EXISTS (SELECT 1 FROM Drugs WHERE Code = 'OMEP004')
   AND EXISTS (SELECT 1 FROM UnitMeasures WHERE Name = 'Gramos')
   AND EXISTS (SELECT 1 FROM Presentations WHERE Name = 'Capsulas')
   AND EXISTS (SELECT 1 FROM Pharmacys WHERE Name = 'Farmacia Central')
    INSERT INTO Drugs (Code, Name, Symptom, Quantity, Price, Stock, Prescription, Deleted, UnitMeasureId, PresentationId, PharmacyId)
    SELECT 'OMEP004', 'Omeprazol 20mg', 'Acidez estomacal', 14, 320.00, 120, 0, 0,
           (SELECT Id FROM UnitMeasures WHERE Name = 'Gramos'),
           (SELECT Id FROM Presentations WHERE Name = 'Capsulas'),
           (SELECT Id FROM Pharmacys WHERE Name = 'Farmacia Central');
GO

PRINT 'Datos iniciales insertados correctamente.';
PRINT 'Usuarios de prueba: admin, owner001, empleado01';
PRINT 'Password para todos: Abcdef12.';
PRINT '';
PRINT 'Roles: Administrator, Employee, Owner';
GO